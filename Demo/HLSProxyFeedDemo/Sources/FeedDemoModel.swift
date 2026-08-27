import CoreGraphics
import Foundation
import Observation
import ProxyPlayerKit

struct FeedDemoMetrics: Equatable, Sendable {
    var firstFrameCount: UInt64 = 0
    var firstFrameP95: TimeInterval?
    var stallCount: UInt64 = 0
    var stallSeconds: TimeInterval = 0
    var cacheHitRate: Double?
    var memoryBytes = 0
    var diskBytes = 0
    var playerCount = 0
    var playerLimit = 0
    var cancellationCount: UInt64 = 0
    var acknowledgedCancellationCount: UInt64 = 0
    var handoffReadyCount: UInt64 = 0
    var handoffSuccessCount: UInt64 = 0
}

enum FeedDemoStatus: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed(String)
}

@Observable
@MainActor
final class FeedDemoModel {
    private(set) var selectedMode: FeedDemoMode = .shortForm
    private(set) var status: FeedDemoStatus = .idle
    private(set) var entries: [FeedDemoEntry] = []
    private(set) var engine: HLSFeedEngine?
    private(set) var engineSnapshot = HLSFeedEngineSnapshot.empty
    private(set) var metrics = FeedDemoMetrics()
    private(set) var focusedItemID: FeedItemID?
    private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var origin: FeedDemoFixtureOrigin?
    @ObservationIgnored private var signalBuilder = FeedDemoSignalBuilder(orderedItemIDs: [])
    @ObservationIgnored private var latestFrames: [FeedItemID: CGRect] = [:]
    @ObservationIgnored private var latestViewport = CGRect.zero
    @ObservationIgnored private var engineUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var telemetryTask: Task<Void, Never>?
    @ObservationIgnored private var signalTask: Task<Void, Never>?

    func start() async {
        guard origin == nil else { return }
        status = .starting
        do {
            let fixtureOrigin = try FeedDemoFixtureOrigin()
            let baseURL = try await fixtureOrigin.start()
            origin = fixtureOrigin
            startedAt = clock.now
            try await install(mode: selectedMode, baseURL: baseURL)
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func select(_ mode: FeedDemoMode) async {
        guard mode != selectedMode || engine == nil else { return }
        selectedMode = mode
        guard let baseURL = origin?.baseURL else { return }
        status = .starting
        do {
            try await install(mode: mode, baseURL: baseURL)
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func observe(frames: [FeedItemID: CGRect], viewport: CGRect) {
        latestFrames = frames
        latestViewport = viewport
        submitSignal(requestedFocus: nil)
    }

    func requestFocus(_ itemID: FeedItemID) {
        submitSignal(requestedFocus: itemID)
    }

    func setLowPowerModeEnabled(_ isEnabled: Bool) async {
        guard let engine else { return }
        do {
            engineSnapshot = try await engine.setLowPowerModeEnabled(isEnabled)
            isLowPowerModeEnabled = isEnabled
            refreshMetrics(engine: engine, policy: selectedMode.policy)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func jumpToLive() async {
        do {
            try await engine?.jumpToLive()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func seekBehindLiveEdge(seconds: TimeInterval) async {
        do {
            try await engine?.seek(secondsBehindLiveEdge: seconds)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        signalTask?.cancel()
        engineUpdatesTask?.cancel()
        telemetryTask?.cancel()
        signalTask = nil
        engineUpdatesTask = nil
        telemetryTask = nil
        if let engine {
            await engine.stop()
        }
        self.engine = nil
        origin?.stop()
        origin = nil
        entries = []
        engineSnapshot = .empty
        metrics = FeedDemoMetrics()
        status = .idle
    }

    private func install(mode: FeedDemoMode, baseURL: URL) async throws {
        signalTask?.cancel()
        engineUpdatesTask?.cancel()
        telemetryTask?.cancel()
        if let engine {
            await engine.stop()
        }

        let nextEntries = FeedDemoCatalog.entries(for: mode, baseURL: baseURL)
        let policy = mode.policy
        let nextEngine = try HLSFeedEngine(
            items: nextEntries.map(\.item),
            policy: policy,
            sourceTransportPolicy: .allowLoopbackHTTP
        )
        entries = nextEntries
        engine = nextEngine
        engineSnapshot = .empty
        metrics = FeedDemoMetrics(playerLimit: policy.concurrency.maximumPlayerCount)
        focusedItemID = nil
        signalBuilder = FeedDemoSignalBuilder(orderedItemIDs: nextEntries.map(\.id))
        latestFrames = [:]
        latestViewport = .zero
        observeEngine(nextEngine, policy: policy)

        if let first = nextEntries.first {
            let viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
            let frames = [first.id: viewport]
            latestFrames = frames
            latestViewport = viewport
            submitSignal(requestedFocus: first.id)
        }
    }

    private func observeEngine(_ observedEngine: HLSFeedEngine, policy: FeedPlaybackPolicy) {
        engineUpdatesTask = Task { @MainActor [weak self, weak observedEngine] in
            guard let observedEngine else { return }
            for await snapshot in observedEngine.updates() {
                guard !Task.isCancelled,
                      let self,
                      self.engine === observedEngine
                else {
                    return
                }
                self.engineSnapshot = snapshot
                self.focusedItemID = snapshot.targetFocusedItemID
                self.refreshMetrics(engine: observedEngine, policy: policy)
            }
        }
        telemetryTask = Task { @MainActor [weak self, weak observedEngine] in
            guard let observedEngine else { return }
            for await _ in observedEngine.telemetry.events() {
                guard !Task.isCancelled,
                      let self,
                      self.engine === observedEngine
                else {
                    return
                }
                self.refreshMetrics(engine: observedEngine, policy: policy)
            }
        }
    }

    private func submitSignal(requestedFocus: FeedItemID?) {
        guard let engine,
              let startedAt,
              let signal = signalBuilder.makeSignal(
                frames: latestFrames,
                viewport: latestViewport,
                observedAt: startedAt.duration(to: clock.now),
                requestedFocus: requestedFocus
              )
        else {
            return
        }
        focusedItemID = signal.focusedItemID
        signalTask?.cancel()
        signalTask = Task { @MainActor [weak self, weak engine] in
            guard let engine else { return }
            do {
                let snapshot = try await engine.update(signal)
                guard !Task.isCancelled,
                      let self,
                      self.engine === engine
                else {
                    return
                }
                self.engineSnapshot = snapshot
                self.refreshMetrics(engine: engine, policy: self.selectedMode.policy)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.engine === engine else { return }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshMetrics(engine: HLSFeedEngine, policy: FeedPlaybackPolicy) {
        let snapshot = engine.telemetry.snapshot
        let cacheHits = snapshot.paths.reduce(UInt64(0)) { $0 &+ $1.cacheHitCount }
        let cacheMisses = snapshot.paths.reduce(UInt64(0)) { $0 &+ $1.cacheMissCount }
        let cacheTotal = cacheHits &+ cacheMisses
        metrics = FeedDemoMetrics(
            firstFrameCount: snapshot.firstFrameCount,
            firstFrameP95: snapshot.paths.compactMap {
                $0.firstFrameLatency.approximateQuantile(0.95)
            }.max(),
            stallCount: snapshot.stallCount,
            stallSeconds: snapshot.paths.reduce(0) { $0 + $1.stallDuration.sum },
            cacheHitRate: cacheTotal == 0 ? nil : Double(cacheHits) / Double(cacheTotal),
            memoryBytes: snapshot.resources.memoryResidentBytes,
            diskBytes: snapshot.resources.diskResidentBytes,
            playerCount: engine.snapshot.poolOccupancy,
            playerLimit: policy.concurrency.maximumPlayerCount,
            cancellationCount: snapshot.cancellationCount,
            acknowledgedCancellationCount: snapshot.paths.reduce(UInt64(0)) {
                $0 &+ $1.cancellationOutcomeCounts[.acknowledged, default: 0]
            },
            handoffReadyCount: snapshot.paths.reduce(UInt64(0)) { $0 &+ $1.handoffReadyCount },
            handoffSuccessCount: snapshot.handoffSuccessCount
        )
    }
}
