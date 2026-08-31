import AVFoundation
import Foundation
import HLSCore
import Observation

/// A read-only view of one engine-owned playback lease.
public struct HLSFeedPlayback: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case loading
        case warm
        case focused
        case failed(String)
    }

    public let itemID: FeedItemID
    public let generation: FeedNavigationGeneration
    public let role: FeedPlan.Role
    public let phase: Phase
    public let state: PlayerState
    /// True after the focused platform player has entered its `.playing`
    /// time-control state for this lease.
    public let hasStartedPlayback: Bool
    /// True only for the current, unsuspended focus owner. Warm and loading
    /// leases are always muted even while AVFoundation primes their pipeline.
    public let isAudible: Bool

    public var isImmediatelyPlayable: Bool {
        phase == .warm || phase == .focused
    }
}

/// Fixed-size state for the automatic feed engine.
public struct HLSFeedEngineSnapshot: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let itemID: FeedItemID
        public let generation: FeedNavigationGeneration
        public let message: String
    }

    public let generation: FeedNavigationGeneration?
    public let targetFocusedItemID: FeedItemID?
    public let activeItemID: FeedItemID?
    public let audibleItemID: FeedItemID?
    public let requestedDestinationItemID: FeedItemID?
    public let playbacks: [HLSFeedPlayback]
    public let failures: [Failure]
    public let poolOccupancy: Int
    public let allocatedPlayerCount: Int
    public let activeLoadCount: Int
    public let maximumObservedPoolOccupancy: Int
    public let maximumObservedAudiblePlaybackCount: Int
    public let staleCompletionCount: Int
    public let isPlaybackSuspended: Bool

    public static let empty = Self(
        generation: nil,
        targetFocusedItemID: nil,
        activeItemID: nil,
        audibleItemID: nil,
        requestedDestinationItemID: nil,
        playbacks: [],
        failures: [],
        poolOccupancy: 0,
        allocatedPlayerCount: 0,
        activeLoadCount: 0,
        maximumObservedPoolOccupancy: 0,
        maximumObservedAudiblePlaybackCount: 0,
        staleCompletionCount: 0,
        isPlaybackSuspended: false
    )

    public func playback(for itemID: FeedItemID) -> HLSFeedPlayback? {
        playbacks.first { $0.itemID == itemID }
    }
}

public enum HLSFeedEngineError: Error, Equatable, LocalizedError, Sendable {
    case stopped
    case backgroundWarmingUnavailable
    case noFocusedItem
    case itemUnavailable(FeedItemID)
    case disallowedSourceURL(URL)
    case untypedClipSequenceRequiresCompatibility(FeedItemID)
    case playerFailed(FeedItemID, String)

    public var errorDescription: String? {
        switch self {
        case .stopped:
            "The feed engine has been stopped"
        case .backgroundWarmingUnavailable:
            "Background warming is unavailable for this injected feed engine"
        case .noFocusedItem:
            "The feed engine has no focused playback item"
        case .itemUnavailable(let itemID):
            "The feed item is not currently owned by the playback pool: \(itemID)"
        case .disallowedSourceURL(let url):
            "The feed source URL is not permitted by the transport policy: \(url.absoluteString)"
        case .untypedClipSequenceRequiresCompatibility(let itemID):
            "Feed item \(itemID) must use compatibleClips to create one stitched playback timeline"
        case .playerFailed(let itemID, let message):
            "Feed item \(itemID) failed to load: \(message)"
        }
    }
}

@MainActor
protocol HLSFeedPlayerSession: AnyObject {
    var state: PlayerState { get }
    var feedPlatformPlayer: AVPlayer? { get }

    func stateUpdates() -> AsyncStream<PlayerState>
    func telemetryUpdates() async -> AsyncStream<HLSStreamingTelemetry.Snapshot>
    func load(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy) async
    func load(clips: [ProxyPlaybackClip]) async throws
    func prepareForImmediatePlayback(
        retryPolicy: HLSFeedPlayerPreparationRetryPolicy
    ) async -> Bool
    func play()
    func pause()
    func setMuted(_ isMuted: Bool)
    func setPlaybackRate(_ rate: Float)
    func jumpToLive() async throws
    func seek(secondsBehindLiveEdge: TimeInterval) async throws
    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async
    func stopAndWait() async
    func restartPlayback() async
}

extension HLSFeedPlayerSession {
    func telemetryUpdates() async -> AsyncStream<HLSStreamingTelemetry.Snapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func setMuted(_ isMuted: Bool) {
        feedPlatformPlayer?.isMuted = isMuted
    }
}

extension ProxyHLSPlayer: HLSFeedPlayerSession {
    var feedPlatformPlayer: AVPlayer? { player }

    func prepareForImmediatePlayback(
        retryPolicy: HLSFeedPlayerPreparationRetryPolicy
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        // Loading the manifest can finish before buffered publication creates
        // AVPlayer. Treat that interval as startup, not a terminal preroll error.
        while player?.currentItem == nil {
            if case .failed = state.status { return false }
            guard !Task.isCancelled, clock.now < deadline else { return false }
            do {
                try await clock.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        guard let player, let item = player.currentItem else { return false }
        player.pause()

        while player.status == .unknown || item.status == .unknown {
            guard clock.now < deadline else { return false }
            do {
                try await clock.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        guard player.status == .readyToPlay, item.status == .readyToPlay else {
            return false
        }

        for attempt in 1...retryPolicy.maximumAttemptCount {
            guard !Task.isCancelled,
                  player.status == .readyToPlay,
                  item.status == .readyToPlay
            else {
                return false
            }
            let rate = playbackRate
            let didPrepare = await withTaskCancellationHandler {
                await player.preroll(atRate: rate)
            } onCancel: {
                player.cancelPendingPrerolls()
            }
            if didPrepare { return true }
            guard attempt < retryPolicy.maximumAttemptCount,
                  !Task.isCancelled
            else {
                return false
            }
            do {
                // A preroll can be interrupted by a transient media time or
                // rate transition. Linear backoff gives that transition time
                // to settle while the hard attempt cap bounds total latency.
                try await Task.sleep(for: retryPolicy.retryDelay * attempt)
            } catch {
                return false
            }
        }
        return false
    }

    func setMuted(_ isMuted: Bool) {
        setFeedPlaybackMuted(isMuted)
    }

    func restartPlayback() async {
        guard !Task.isCancelled, let player, let item = player.currentItem,
              !player.isMuted else { return }
        item.cancelPendingSeeks()
        // At end-of-item, tvOS can defer seek completion until playback resumes.
        // Submit the rewind and play without a suspension point between them.
        // No completion callback may later restart a retired or muted lease.
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        play()
    }
}

struct HLSFeedPlayerPreparationRetryPolicy: Equatable, Sendable {
    private static let maximumRetryDelay: Duration = .milliseconds(200)

    static let automaticFeed = Self(
        maximumAttemptCount: 5,
        retryDelay: .milliseconds(50)
    )

    let maximumAttemptCount: Int
    let retryDelay: Duration

    init(maximumAttemptCount: Int, retryDelay: Duration) {
        self.maximumAttemptCount = min(max(1, maximumAttemptCount), 5)
        self.retryDelay = min(
            max(.zero, retryDelay),
            Self.maximumRetryDelay
        )
    }
}

/// Owns predictive preparation, a bounded reusable player pool, and atomic
/// focus handoff for an ordered collection of HLS items.
///
/// Applications provide items, one typed policy, and UI-independent viewport
/// signals. The engine owns every `AVPlayer`, proxy listener, scheduler,
/// observer, and cache lease needed by the active working set.
@Observable
@MainActor
public final class HLSFeedEngine {
    private struct Lease {
        let token: UUID
        let itemID: FeedItemID
        var generation: FeedNavigationGeneration
        var role: FeedPlan.Role
        let source: FeedPlaybackSource
        var phase: HLSFeedPlayback.Phase
        var state: PlayerState
        var didCompleteInitialLoad: Bool
        var hasStartedPlayback: Bool
        var isAudible: Bool
        var telemetryPath: HLSFeedTelemetry.Path
        let analyticsAttempt: PlaybackAnalyticsTimeline.Attempt
        var stallStartedAt: Duration?
    }

    private struct PendingFocus {
        let itemID: FeedItemID
        let generation: FeedNavigationGeneration
        let requestedAt: Duration
        let wasReadyAtRequest: Bool
        let path: HLSFeedTelemetry.Path
    }

    @MainActor
    private final class Slot {
        let id = UUID()
        let session: any HLSFeedPlayerSession
        var lease: Lease?
        var loadTask: Task<Void, Never>?
        var observationTask: Task<Void, Never>?
        var streamingTelemetryTask: Task<Void, Never>?
        var avMetricTask: Task<Void, Never>?
        var avMetricCollector: AVPlaybackMetricCollector?
        var releaseTask: Task<Void, Never>?
        var playbackEndObserver: NSObjectProtocol?
        var playbackStartObservation: NSKeyValueObservation?
        var playbackFailureObservation: NSKeyValueObservation?
        var isReleasing = false

        init(session: any HLSFeedPlayerSession) {
            self.session = session
        }

        @discardableResult
        func cancelLeaseObservers() -> Task<Void, Never>? {
            let task = observationTask
            task?.cancel()
            observationTask = nil
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
                self.playbackEndObserver = nil
            }
            playbackStartObservation?.invalidate()
            playbackStartObservation = nil
            playbackFailureObservation?.invalidate()
            playbackFailureObservation = nil
            return task
        }

        func cancelAnalyticsObservers() -> [Task<Void, Never>] {
            let tasks = [streamingTelemetryTask, avMetricTask].compactMap { $0 }
            streamingTelemetryTask?.cancel()
            streamingTelemetryTask = nil
            avMetricTask?.cancel()
            avMetricTask = nil
            avMetricCollector?.stop()
            avMetricCollector = nil
            return tasks
        }
    }

    typealias SessionFactory = @MainActor (ProxyPlayerConfiguration) -> any HLSFeedPlayerSession

    public private(set) var snapshot = HLSFeedEngineSnapshot.empty
    public private(set) var requestedDestinationItemID: FeedItemID?
    /// Observation snapshot, bounded events, signposts, and JSON summaries for
    /// the complete automatic feed lifecycle.
    public let telemetry: HLSFeedTelemetry
    /// One ordered, privacy-bounded timeline spanning feed, player, proxy,
    /// origin, cache, scheduler, and native AVFoundation metrics.
    public let analytics: PlaybackAnalyticsTimeline
    /// Player-free opportunistic warming backed by the engine's persistent
    /// segment cache. Production initializers always provide this service.
    public let backgroundWarmer: HLSFeedBackgroundWarmer?

    @ObservationIgnored private var items: [FeedPlaybackItem]
    @ObservationIgnored private var itemsByID: [FeedItemID: FeedPlaybackItem]
    @ObservationIgnored private var basePolicy: FeedPlaybackPolicy
    @ObservationIgnored private var effectivePolicy: FeedPlaybackPolicy
    @ObservationIgnored private let sourceTransportPolicy: HLSFeedSourceTransportPolicy
    @ObservationIgnored private var playerConfiguration: ProxyPlayerConfiguration
    @ObservationIgnored private let coordinator: FeedCoordinator
    @ObservationIgnored private let sessionFactory: SessionFactory
    @ObservationIgnored private let sharedCache: HLSSegmentCache?
    @ObservationIgnored private let telemetryClock: FeedCoordinatorClock
    @ObservationIgnored private let playerPreparationRetryPolicy:
        HLSFeedPlayerPreparationRetryPolicy
    @ObservationIgnored private var slots: [Slot] = []
    @ObservationIgnored private var slotIDByItemID: [FeedItemID: UUID] = [:]
    @ObservationIgnored private var desiredItemIDs: Set<FeedItemID> = []
    @ObservationIgnored private var failuresByItemID: [FeedItemID: HLSFeedEngineSnapshot.Failure] = [:]
    @ObservationIgnored private var targetFocusedItemID: FeedItemID?
    @ObservationIgnored private var activeItemID: FeedItemID?
    @ObservationIgnored private var latestCoordinatorSnapshot: FeedCoordinatorSnapshot?
    @ObservationIgnored private var coordinatorObservationTask: Task<Void, Never>?
    @ObservationIgnored private var cacheSampleTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<HLSFeedEngineSnapshot>.Continuation] = [:]
    @ObservationIgnored private var maximumObservedPoolOccupancy = 0
    @ObservationIgnored private var maximumObservedAudiblePlaybackCount = 0
    @ObservationIgnored private var staleCompletionCount = 0
    @ObservationIgnored private var pendingFocus: PendingFocus?
    @ObservationIgnored private var latestCancellationAcknowledgementCount = 0
    @ObservationIgnored private var latestLateCancellationCount = 0
    @ObservationIgnored private var cacheMetrics = HLSSegmentCache.Metrics(
        hitCount: 0,
        missCount: 0,
        totalBytes: 0,
        diskBytes: 0
    )
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var isPlaybackSuspended = false

    /// Creates a production engine with one shared bounded cache underneath
    /// predictive preparation and all pooled playback sessions.
    public convenience init(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        sourceTransportPolicy: HLSFeedSourceTransportPolicy = .secureOnly,
        backgroundWarmingPolicy: HLSFeedBackgroundWarmingPolicy = .shortFormFeed,
        telemetryConfiguration: HLSFeedTelemetry.Configuration = .init(),
        analyticsConfiguration: PlaybackAnalyticsTimeline.Configuration = .init()
    ) throws {
        let validatedPolicy = try policy.validated()
        try Self.validateSourceURLs(in: items, policy: sourceTransportPolicy)
        let telemetry = HLSFeedTelemetry(configuration: telemetryConfiguration)
        let analytics = PlaybackAnalyticsTimeline(configuration: analyticsConfiguration)
        let sharedCache = Self.makeSharedCache(policy: validatedPolicy)
        let backend = try HLSFeedPreparationBackend(
            policy: validatedPolicy,
            allowsInsecureManifests: sourceTransportPolicy.allowsInsecureManifests,
            cache: sharedCache
        )
        let coordinator = try FeedCoordinator(
            items: items,
            policy: validatedPolicy,
            backend: backend
        )
        let backgroundWarmer = try HLSFeedBackgroundWarmer(
            feedPolicy: validatedPolicy,
            policy: backgroundWarmingPolicy,
            sourceTransportPolicy: sourceTransportPolicy,
            sharedCache: sharedCache
        )
        try self.init(
            items: items,
            policy: validatedPolicy,
            coordinator: coordinator,
            sessionFactory: { configuration in
                ProxyHLSPlayer(configuration: configuration, sharedCache: sharedCache)
            },
            telemetry: telemetry,
            analytics: analytics,
            backgroundWarmer: backgroundWarmer,
            sharedCache: sharedCache,
            sourceTransportPolicy: sourceTransportPolicy
        )
    }

    init(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        coordinator: FeedCoordinator,
        sessionFactory: @escaping SessionFactory,
        telemetry: HLSFeedTelemetry = HLSFeedTelemetry(),
        analytics: PlaybackAnalyticsTimeline = PlaybackAnalyticsTimeline(),
        backgroundWarmer: HLSFeedBackgroundWarmer? = nil,
        sharedCache: HLSSegmentCache? = nil,
        telemetryClock: FeedCoordinatorClock = .continuous,
        playerPreparationRetryPolicy: HLSFeedPlayerPreparationRetryPolicy = .automaticFeed,
        sourceTransportPolicy: HLSFeedSourceTransportPolicy = .secureOnly
    ) throws {
        let validatedPolicy = try policy.validated()
        self.items = items
        self.itemsByID = try Self.validatedItemsByID(items)
        self.basePolicy = validatedPolicy
        self.effectivePolicy = validatedPolicy
        self.sourceTransportPolicy = sourceTransportPolicy
        self.playerConfiguration = try Self.playerConfiguration(
            for: validatedPolicy,
            sourceTransportPolicy: sourceTransportPolicy
        )
        self.coordinator = coordinator
        self.sessionFactory = sessionFactory
        self.telemetry = telemetry
        self.analytics = analytics
        self.backgroundWarmer = backgroundWarmer
        self.sharedCache = sharedCache
        self.telemetryClock = telemetryClock
        self.playerPreparationRetryPolicy = playerPreparationRetryPolicy
        startCoordinatorObservation()
    }

    /// Applies one current visibility/focus/velocity/prediction observation.
    /// Warm sessions never autoplay; focus moves only when the destination's
    /// existing player item is ready.
    @discardableResult
    public func update(_ signal: FeedViewportSignal) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let previousPendingFocus = pendingFocus
        let previousTarget = targetFocusedItemID
        let focusChanged = signal.focusedItemID != previousTarget
        let canAffectCurrentFocus = latestCoordinatorSnapshot?.generation.map {
            signal.generation >= $0
        } ?? true
        let didSilenceActivePlayback = focusChanged && canAffectCurrentFocus
        if didSilenceActivePlayback {
            deactivateActivePlayback()
        }
        if focusChanged {
            pendingFocus = signal.focusedItemID.map {
                makePendingFocus(itemID: $0, generation: signal.generation)
            }
        }
        let value: FeedCoordinatorSnapshot
        do {
            value = try await coordinator.submit(signal)
        } catch {
            if pendingFocus?.generation == signal.generation {
                pendingFocus = previousPendingFocus
            }
            if didSilenceActivePlayback,
               let previousTarget,
               let previous = slot(for: previousTarget) {
                activate(previous)
            }
            throw error
        }
        if value.generation == signal.generation {
            if focusChanged, let previousPendingFocus {
                recordPendingFocus(previousPendingFocus, succeeded: false)
            }
            targetFocusedItemID = signal.focusedItemID
            requestedDestinationItemID = nil
            failuresByItemID.removeAll(keepingCapacity: true)
            // coordinator.submit suspends this MainActor method. Its observation
            // task may publish during that suspension and reactivate the old
            // target, so close the reentrancy window before accepting the new
            // generation. A ready destination is activated immediately below.
            if didSilenceActivePlayback,
               let activeItemID,
               activeItemID != targetFocusedItemID {
                deactivateActivePlayback()
            }
        } else if pendingFocus?.generation == signal.generation {
            pendingFocus = previousPendingFocus
            if didSilenceActivePlayback,
               let previousTarget,
               let previous = slot(for: previousTarget) {
                activate(previous)
            }
        }
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Releases all memory-resident cache bytes while retaining valid disk
    /// entries for later reuse. UI lifecycle code can forward the platform's
    /// memory-pressure signal here without owning players or cache instances.
    public func handleMemoryPressure() async {
        await sharedCache?.handleMemoryPressure()
        if let sharedCache {
            cacheMetrics = await sharedCache.metrics()
            rebuildSnapshot()
        }
    }

    /// Runs one system-granted, strictly bounded background opportunity without
    /// exposing players, proxy servers, fetchers, or cache objects to the host.
    @discardableResult
    public func warmInBackground(
        _ request: HLSFeedBackgroundWarmingRequest
    ) async throws -> HLSFeedBackgroundWarmingResult {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        guard let backgroundWarmer else {
            throw HLSFeedEngineError.backgroundWarmingUnavailable
        }
        return await backgroundWarmer.warm(request)
    }

    /// Atomically replaces the independent caps for future background work.
    public func updateBackgroundWarmingPolicy(
        _ policy: HLSFeedBackgroundWarmingPolicy
    ) async throws {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        guard let backgroundWarmer else {
            throw HLSFeedEngineError.backgroundWarmingUnavailable
        }
        try await backgroundWarmer.updatePolicy(policy)
    }

    /// Suspends audible playback without discarding the prepared working set.
    /// Hosts can forward inactive/background lifecycle state here and resume
    /// later without manually pausing or recreating pooled players.
    @discardableResult
    public func setPlaybackSuspended(_ isSuspended: Bool) -> HLSFeedEngineSnapshot {
        guard !isStopped, isPlaybackSuspended != isSuspended else { return snapshot }
        isPlaybackSuspended = isSuspended
        if isSuspended {
            if pendingFocus != nil { completePendingFocus(succeeded: false) }
            recordPlaybackLifecycle(.backgrounded)
            deactivateActivePlayback()
        } else {
            recordPlaybackLifecycle(.resumed)
            if let targetFocusedItemID,
               let destination = slot(for: targetFocusedItemID) {
                activate(destination)
            }
        }
        rebuildSnapshot()
        return snapshot
    }

    /// Replaces feed contents while retaining leases only for identical items.
    @discardableResult
    public func replaceItems(
        _ items: [FeedPlaybackItem]
    ) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        try Self.validateSourceURLs(in: items, policy: sourceTransportPolicy)
        let replacement = try Self.validatedItemsByID(items)
        let value = try await coordinator.replaceItems(items)
        for slot in slots {
            guard let lease = slot.lease,
                  replacement[lease.itemID]?.source != lease.source
            else { continue }
            await release(slot, token: lease.token)
        }
        self.items = items
        self.itemsByID = replacement
        if let targetFocusedItemID, replacement[targetFocusedItemID] == nil {
            self.targetFocusedItemID = nil
        }
        if let requestedDestinationItemID, replacement[requestedDestinationItemID] == nil {
            self.requestedDestinationItemID = nil
        }
        if let pendingFocus, replacement[pendingFocus.itemID] == nil {
            completePendingFocus(succeeded: false)
        }
        failuresByItemID = failuresByItemID.filter { replacement[$0.key] != nil }
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Revalidates and atomically applies a new base policy.
    @discardableResult
    public func updatePolicy(
        _ policy: FeedPlaybackPolicy
    ) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let validatedPolicy = try policy.validated()
        let configuration = try Self.playerConfiguration(
            for: validatedPolicy,
            sourceTransportPolicy: sourceTransportPolicy
        )
        try await backgroundWarmer?.updateFeedPolicy(validatedPolicy)
        let value = try await coordinator.updatePolicy(validatedPolicy)
        basePolicy = validatedPolicy
        effectivePolicy = validatedPolicy
        playerConfiguration = configuration
        for slot in slots {
            await slot.session.updateConfiguration(playerConfiguration)
        }
        await trimPoolIfNeeded()
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Applies the policy's low-power caps to preparation and player ownership.
    @discardableResult
    public func setLowPowerModeEnabled(
        _ isEnabled: Bool
    ) async throws -> HLSFeedEngineSnapshot {
        guard !isStopped else { throw HLSFeedEngineError.stopped }
        let adaptedPolicy = try basePolicy.adaptedForLowPowerMode(isEnabled)
        let configuration = try Self.playerConfiguration(
            for: adaptedPolicy,
            sourceTransportPolicy: sourceTransportPolicy
        )
        let value = try await coordinator.setLowPowerModeEnabled(isEnabled)
        effectivePolicy = adaptedPolicy
        playerConfiguration = configuration
        for slot in slots {
            await slot.session.updateConfiguration(playerConfiguration)
        }
        await trimPoolIfNeeded()
        acceptCoordinatorSnapshot(value)
        return snapshot
    }

    /// Bounded newest-only state for non-Observation consumers.
    public func updates() -> AsyncStream<HLSFeedEngineSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Waits for currently admitted preparation and player-loading work.
    @discardableResult
    public func waitUntilSettled() async -> HLSFeedEngineSnapshot {
        guard !isStopped else { return snapshot }
        let value = await coordinator.waitUntilIdle()
        acceptCoordinatorSnapshot(value)
        while true {
            let tasks = slots.compactMap(\.loadTask) + slots.compactMap(\.releaseTask)
            guard !tasks.isEmpty else { break }
            for task in tasks { await task.value }
        }
        return snapshot
    }

    public func playback(for itemID: FeedItemID) -> HLSFeedPlayback? {
        snapshot.playback(for: itemID)
    }

    public func setPlaybackRate(_ rate: Float, for itemID: FeedItemID? = nil) throws {
        let resolvedItemID = try controlledItemID(itemID)
        guard let slot = slot(for: resolvedItemID) else {
            throw HLSFeedEngineError.itemUnavailable(resolvedItemID)
        }
        slot.session.setPlaybackRate(rate)
    }

    public func jumpToLive(for itemID: FeedItemID? = nil) async throws {
        let resolvedItemID = try controlledItemID(itemID)
        guard let slot = slot(for: resolvedItemID) else {
            throw HLSFeedEngineError.itemUnavailable(resolvedItemID)
        }
        try await slot.session.jumpToLive()
    }

    public func seek(
        secondsBehindLiveEdge: TimeInterval,
        for itemID: FeedItemID? = nil
    ) async throws {
        let resolvedItemID = try controlledItemID(itemID)
        guard let slot = slot(for: resolvedItemID) else {
            throw HLSFeedEngineError.itemUnavailable(resolvedItemID)
        }
        try await slot.session.seek(secondsBehindLiveEdge: secondsBehindLiveEdge)
    }

    /// Cancels all preparation, load, observation, grace-period, and listener
    /// work and waits for every pooled session to finish teardown.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        // Silence every lease before the first suspension point. Coordinator,
        // background, and session teardown may take time, but no retained
        // platform player is allowed to remain audible during that work.
        let retainedPlatformPlayers = slots.compactMap { $0.session.feedPlatformPlayer }
        deactivateActivePlayback()
        if pendingFocus != nil { completePendingFocus(succeeded: false) }
        let coordinatorObservationTask = coordinatorObservationTask
        let cacheSampleTask = cacheSampleTask
        coordinatorObservationTask?.cancel()
        cacheSampleTask?.cancel()
        self.coordinatorObservationTask = nil
        self.cacheSampleTask = nil
        await backgroundWarmer?.stop()
        await coordinator.stop()

        let loadTasks = slots.compactMap(\.loadTask)
        let releaseTasks = slots.compactMap(\.releaseTask)
        let observationTasks = slots.compactMap(\.observationTask)
        let analyticsAttempts = slots.compactMap { $0.lease?.analyticsAttempt }
        var analyticsTasks: [Task<Void, Never>] = []
        for slot in slots {
            slot.isReleasing = true
            if var lease = slot.lease {
                finishStallIfNeeded(in: &lease)
                lease.isAudible = false
                slot.lease = lease
            }
            slot.loadTask?.cancel()
            slot.releaseTask?.cancel()
            slot.cancelLeaseObservers()
            analyticsTasks += slot.cancelAnalyticsObservers()
            slot.session.setMuted(true)
            slot.session.pause()
        }
        await coordinatorObservationTask?.value
        await cacheSampleTask?.value
        for task in loadTasks { await task.value }
        for task in releaseTasks { await task.value }
        for task in observationTasks { await task.value }
        for task in analyticsTasks { await task.value }
        for slot in slots { await slot.session.stopAndWait() }
        // Session teardown releases its engine-owned AVPlayer reference. Keep
        // external read-only references silent even if a late AVFoundation
        // callback raced with observer cancellation while teardown awaited.
        for player in retainedPlatformPlayers {
            Self.silenceRetiredPlayer(player)
        }
        for attempt in analyticsAttempts where analytics.isActive(attempt) {
            analytics.end(attempt, lifecycle: .cancelled)
        }

        slots.removeAll()
        slotIDByItemID.removeAll()
        desiredItemIDs.removeAll()
        failuresByItemID.removeAll()
        activeItemID = nil
        targetFocusedItemID = nil
        requestedDestinationItemID = nil
        latestCoordinatorSnapshot = nil
        rebuildSnapshot()
        telemetry.finish()
        analytics.finish()
        for continuation in continuations.values {
            continuation.yield(snapshot)
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// The rendering layer uses this read-only reference; ownership remains in
    /// the engine and disappears when its lease is recycled.
    func platformPlayer(for itemID: FeedItemID) -> AVPlayer? {
        slot(for: itemID)?.session.feedPlatformPlayer
    }

    func notifyPlaybackEnded(for itemID: FeedItemID) async {
        guard let slot = slot(for: itemID), let token = slot.lease?.token else { return }
        await playbackEnded(in: slot, token: token)
    }

    private func startCoordinatorObservation() {
        let coordinator = coordinator
        coordinatorObservationTask = Task { @MainActor [weak self] in
            let updates = await coordinator.updates()
            for await value in updates {
                guard !Task.isCancelled, let self, !self.isStopped else { return }
                self.acceptCoordinatorSnapshot(value)
            }
        }
    }

    private func acceptCoordinatorSnapshot(_ value: FeedCoordinatorSnapshot) {
        guard !isStopped else { return }
        if let current = latestCoordinatorSnapshot?.generation,
           let incoming = value.generation,
           incoming < current {
            return
        }
        latestCoordinatorSnapshot = value
        ingestCancellationMetrics(from: value)
        desiredItemIDs = Set(value.entries.map(\.itemID))

        for slot in slots where slot.lease.map({ !desiredItemIDs.contains($0.itemID) }) == true {
            scheduleRelease(of: slot)
        }

        for entry in value.entries {
            guard case .ready(let prepared) = entry.status,
                  let item = itemsByID[entry.itemID],
                  let generation = value.generation
            else { continue }
            ensureLease(
                for: item,
                prepared: prepared,
                generation: generation,
                role: entry.role
            )
        }

        if !isPlaybackSuspended,
           let targetFocusedItemID,
           let slot = slot(for: targetFocusedItemID),
           slot.lease.map({ $0.phase == .warm || $0.phase == .focused }) == true {
            activate(slot)
        }
        rebuildSnapshot()
        scheduleCacheSample()
    }

    private func ensureLease(
        for item: FeedPlaybackItem,
        prepared: FeedPreparedItem,
        generation: FeedNavigationGeneration,
        role: FeedPlan.Role
    ) {
        if let slot = slot(for: item.id), var lease = slot.lease, lease.source == item.source {
            slot.releaseTask?.cancel()
            slot.releaseTask = nil
            lease.generation = generation
            lease.role = role
            lease.telemetryPath = Self.telemetryPath(
                reuse: lease.telemetryPath.reuse,
                role: role,
                source: item.source
            )
            analytics.updateAttribution(
                Self.analyticsAttribution(from: lease.telemetryPath),
                for: lease.analyticsAttempt
            )
            slot.lease = lease
            return
        }

        guard let slot = availableSlot(for: role) else { return }
        failuresByItemID.removeValue(forKey: item.id)
        assign(
            item,
            prepared: prepared,
            generation: generation,
            role: role,
            to: slot
        )
    }

    private func availableSlot(for role: FeedPlan.Role) -> Slot? {
        if let idle = slots.first(where: { $0.lease == nil && !$0.isReleasing }) { return idle }
        if slots.count < effectivePolicy.concurrency.maximumPlayerCount {
            let slot = Slot(session: sessionFactory(playerConfiguration))
            slots.append(slot)
            return slot
        }

        let reclaimable = slots.reversed().first { slot in
            guard !slot.isReleasing else { return false }
            guard let lease = slot.lease else { return true }
            return lease.itemID != activeItemID
                && (!desiredItemIDs.contains(lease.itemID) || lease.role.rawValue > role.rawValue)
        }
        if let reclaimable { return reclaimable }
        if role == .focused {
            return slots.first {
                !$0.isReleasing && $0.lease?.itemID == activeItemID
            }
        }
        return nil
    }

    private func assign(
        _ item: FeedPlaybackItem,
        prepared: FeedPreparedItem,
        generation: FeedNavigationGeneration,
        role: FeedPlan.Role,
        to slot: Slot
    ) {
        let previousTask = slot.loadTask
        let playerCancellationRequestedAt = previousTask.map { _ in telemetryClock.now() }
        let playerCancellationPath = slot.lease?.telemetryPath
        let previousAnalyticsAttempt = slot.lease?.analyticsAttempt
        let previousAnalyticsTasks = slot.cancelAnalyticsObservers()
        let hadPreviousLease = slot.lease != nil
        let retiredPlatformPlayer = hadPreviousLease ? slot.session.feedPlatformPlayer : nil
        previousTask?.cancel()
        slot.releaseTask?.cancel()
        slot.releaseTask = nil
        slot.cancelLeaseObservers()
        if let oldItemID = slot.lease?.itemID {
            slotIDByItemID.removeValue(forKey: oldItemID)
            if activeItemID == oldItemID { activeItemID = nil }
        }

        let token = UUID()
        let reuse: HLSFeedTelemetry.Reuse = prepared.isPreparationReuse
            || (prepared.originFetchCount == 0 && prepared.cacheHitCount > 0)
            ? .warm
            : .cold
        let telemetryPath = Self.telemetryPath(
            reuse: reuse,
            role: role,
            source: item.source
        )
        let analyticsAttempt = analytics.beginAttempt(
            attribution: Self.analyticsAttribution(from: telemetryPath)
        )
        slot.session.setMuted(true)
        if hadPreviousLease { slot.session.pause() }
        slot.lease = Lease(
            token: token,
            itemID: item.id,
            generation: generation,
            role: role,
            source: item.source,
            phase: .loading,
            state: slot.session.state,
            didCompleteInitialLoad: false,
            hasStartedPlayback: false,
            isAudible: false,
            telemetryPath: telemetryPath,
            analyticsAttempt: analyticsAttempt,
            stallStartedAt: nil
        )
        slotIDByItemID[item.id] = slot.id
        maximumObservedPoolOccupancy = max(maximumObservedPoolOccupancy, slotIDByItemID.count)
        analytics.record(prepared: prepared, attempt: analyticsAttempt)
        recordTelemetry(.init(
            path: telemetryPath,
            payload: .cache(
                hits: prepared.cacheHitCount,
                misses: prepared.originFetchCount,
                originBytesAvoided: prepared.cacheHitByteCount
            )
        ), attempt: analyticsAttempt)
        // The analytics preparation event above already carries origin requests
        // and bytes. Feed telemetry owns its separate aggregate without emitting
        // the same values into the correlated analytics timeline twice.
        telemetry.record(.init(
            path: telemetryPath,
            payload: .network(
                originRequests: prepared.originFetchCount,
                originBytesFetched: prepared.originFetchByteCount
            )
        ))

        let configuration = playerConfiguration
        slot.loadTask = Task { @MainActor [weak self, weak slot] in
            if let previousTask {
                await previousTask.value
                if let self, let playerCancellationRequestedAt, let playerCancellationPath {
                    self.recordTelemetry(.init(
                        path: playerCancellationPath,
                        payload: .cancellation(
                            latency: Self.seconds(
                                self.telemetryClock.now() - playerCancellationRequestedAt
                            ),
                            outcome: .acknowledged
                        )
                    ), attempt: previousAnalyticsAttempt)
                }
            }
            for task in previousAnalyticsTasks { await task.value }
            if let self, let previousAnalyticsAttempt {
                self.analytics.end(previousAnalyticsAttempt, lifecycle: .cancelled)
            }
            guard let self, let slot, self.owns(slot, token: token) else { return }
            if hadPreviousLease {
                await slot.session.stopAndWait()
                Self.silenceRetiredPlayer(retiredPlatformPlayer)
            }
            guard self.owns(slot, token: token), !Task.isCancelled else {
                self.recordStaleCompletion()
                return
            }
            await slot.session.updateConfiguration(configuration)
            guard self.owns(slot, token: token), !Task.isCancelled else {
                self.recordStaleCompletion()
                return
            }
            self.startStateObservation(for: slot, token: token)
            self.startStreamingTelemetryObservation(for: slot, token: token)
            do {
                try await self.load(
                    item: item,
                    quality: configuration.qualityPolicy,
                    into: slot.session
                )
                guard self.owns(slot, token: token), !Task.isCancelled else {
                    self.recordStaleCompletion()
                    return
                }
                slot.session.setMuted(true)
                let isPreparedForImmediatePlayback = await slot.session
                    .prepareForImmediatePlayback(
                        retryPolicy: self.playerPreparationRetryPolicy
                    )
                guard self.owns(slot, token: token), !Task.isCancelled else {
                    self.recordStaleCompletion()
                    return
                }
                guard isPreparedForImmediatePlayback else {
                    throw HLSFeedEngineError.playerFailed(
                        item.id,
                        "AVPlayer could not prime its media pipeline"
                    )
                }
                self.finishLoad(in: slot, token: token)
            } catch is CancellationError {
                if self.owns(slot, token: token) {
                    await self.releaseAfterFailedLoad(slot, token: token, message: "cancelled")
                } else {
                    self.recordStaleCompletion()
                }
            } catch {
                if self.owns(slot, token: token) {
                    await self.releaseAfterFailedLoad(
                        slot,
                        token: token,
                        message: error.localizedDescription
                    )
                } else {
                    self.recordStaleCompletion()
                }
            }
        }
    }

    private func load(
        item: FeedPlaybackItem,
        quality: HLSRewriteConfiguration.QualityPolicy,
        into session: any HLSFeedPlayerSession
    ) async throws {
        switch item.source {
        case .stream(let url, _):
            await session.load(from: url, quality: quality)
            if case .failed(let message) = session.state.status {
                throw HLSFeedEngineError.playerFailed(item.id, message)
            }
        case .compatibleClips(let clips):
            try await session.load(clips: clips)
        case .clips:
            throw HLSFeedEngineError.untypedClipSequenceRequiresCompatibility(item.id)
        }
    }

    private func finishLoad(in slot: Slot, token: UUID) {
        guard owns(slot, token: token), var lease = slot.lease else { return }
        slot.loadTask = nil
        failuresByItemID.removeValue(forKey: lease.itemID)
        lease.state = slot.session.state
        lease.didCompleteInitialLoad = true
        var failedMessage: String?
        if case .failed(let message) = lease.state.status {
            lease.phase = .failed(message)
            failedMessage = message
        } else if lease.state.status == .ready {
            lease.phase = .warm
        } else {
            lease.phase = .loading
        }
        slot.lease = lease
        startAVMetricObservation(for: slot, token: token)
        slot.session.setMuted(true)
        slot.session.pause()
        if let failedMessage {
            failuresByItemID[lease.itemID] = .init(
                itemID: lease.itemID,
                generation: lease.generation,
                message: failedMessage
            )
            slot.releaseTask = Task { @MainActor [weak self, weak slot] in
                guard let self, let slot, self.owns(slot, token: token) else { return }
                await self.release(slot, token: token)
            }
        } else {
            installPlaybackEndObserver(for: slot, token: token)
        }
        if !isPlaybackSuspended,
           lease.itemID == targetFocusedItemID,
           lease.phase == .warm {
            activate(slot)
        }
        rebuildSnapshot()
    }

    private func startStateObservation(for slot: Slot, token: UUID) {
        // Establish the stream before returning so a session cannot publish its
        // first transition between load completion and observer registration.
        let updates = slot.session.stateUpdates()
        slot.observationTask = Task { @MainActor [weak self, weak slot] in
            guard let slot else { return }
            for await state in updates {
                guard !Task.isCancelled, let self, self.owns(slot, token: token) else { return }
                self.acceptPlayerState(state, from: slot, token: token)
            }
        }
    }

    private func startStreamingTelemetryObservation(for slot: Slot, token: UUID) {
        guard analytics.isEnabled else { return }
        slot.streamingTelemetryTask?.cancel()
        slot.streamingTelemetryTask = Task { @MainActor [weak self, weak slot] in
            guard let slot else { return }
            let updates = await slot.session.telemetryUpdates()
            for await snapshot in updates {
                guard !Task.isCancelled,
                      let self,
                      self.owns(slot, token: token),
                      let attempt = slot.lease?.analyticsAttempt
                else {
                    return
                }
                self.analytics.record(streaming: snapshot, attempt: attempt)
            }
        }
    }

    private func startAVMetricObservation(for slot: Slot, token: UUID) {
        guard analytics.isEnabled,
              let player = slot.session.feedPlatformPlayer,
              let attempt = slot.lease?.analyticsAttempt
        else {
            return
        }
        slot.avMetricTask?.cancel()
        slot.avMetricCollector?.stop()
        let collector = AVPlaybackMetricCollector(
            correlation: attempt.correlation,
            dimensions: analytics.dimensions(
                for: attempt,
                networkLeg: .playerToLocalProxy
            ),
            clock: analytics.clock
        )
        slot.avMetricCollector = collector
        collector.attach(to: player)
        slot.avMetricTask = Task { @MainActor [weak self, weak slot, weak collector] in
            guard let collector else { return }
            for await event in collector.events {
                guard !Task.isCancelled,
                      let self,
                      let slot,
                      self.owns(slot, token: token),
                      slot.avMetricCollector === collector,
                      let attempt = slot.lease?.analyticsAttempt
                else {
                    return
                }
                self.analytics.record(avFoundation: event, attempt: attempt)
            }
        }
    }

    private func acceptPlayerState(_ state: PlayerState, from slot: Slot, token: UUID) {
        guard owns(slot, token: token), var lease = slot.lease else { return }
        let previousState = lease.state
        let previousStatus = lease.state.status
        lease.state = state
        analytics.record(
            player: state,
            previous: previousState,
            attempt: lease.analyticsAttempt
        )
        var shouldReleaseFailedSession = false
        switch state.status {
        case .ready:
            finishStallIfNeeded(in: &lease)
            // AVPlayer can publish `.readyToPlay` before its preroll callback
            // succeeds. Keep the lease loading until the full initial load,
            // including bounded preparation, has completed so observation
            // cannot activate an unprimed player while preparation is retrying.
            if lease.didCompleteInitialLoad, lease.phase == .loading {
                lease.phase = .warm
            }
            if lease.didCompleteInitialLoad, slot.playbackEndObserver == nil {
                installPlaybackEndObserver(for: slot, token: token)
            }
        case .failed(let message):
            finishStallIfNeeded(in: &lease)
            lease.phase = .failed(message)
            lease.hasStartedPlayback = false
            lease.isAudible = false
            slot.session.setMuted(true)
            slot.session.pause()
            failuresByItemID[lease.itemID] = .init(
                itemID: lease.itemID,
                generation: lease.generation,
                message: message
            )
            shouldReleaseFailedSession = lease.didCompleteInitialLoad
        case .buffering:
            if lease.didCompleteInitialLoad,
               lease.phase == .focused,
               previousStatus == .ready,
               lease.stallStartedAt == nil {
                lease.stallStartedAt = telemetryClock.now()
            }
        case .idle:
            finishStallIfNeeded(in: &lease)
        }
        slot.lease = lease
        if shouldReleaseFailedSession, slot.releaseTask == nil {
            slot.releaseTask = Task { @MainActor [weak self, weak slot] in
                guard let self, let slot, self.owns(slot, token: token) else { return }
                await self.release(slot, token: token)
            }
        }
        if !isPlaybackSuspended,
           lease.itemID == targetFocusedItemID,
           lease.phase == .warm {
            activate(slot)
        }
        rebuildSnapshot()
    }

    private func activate(_ destination: Slot) {
        guard !isPlaybackSuspended,
              let targetFocusedItemID,
              let destinationLease = destination.lease,
              destinationLease.itemID == targetFocusedItemID,
              destinationLease.generation == latestCoordinatorSnapshot?.generation,
              destinationLease.phase == .warm || destinationLease.phase == .focused
        else { return }
        if activeItemID == destinationLease.itemID,
           destinationLease.phase == .focused,
           destinationLease.isAudible {
            return
        }
        deactivateActivePlayback()
        guard var destinationLease = destination.lease,
              destinationLease.itemID == targetFocusedItemID,
              destinationLease.generation == latestCoordinatorSnapshot?.generation,
              destinationLease.phase == .warm || destinationLease.phase == .focused
        else { return }
        destinationLease.telemetryPath = Self.telemetryPath(
            reuse: destinationLease.telemetryPath.reuse,
            role: .focused,
            source: destinationLease.source
        )
        analytics.updateAttribution(
            Self.analyticsAttribution(from: destinationLease.telemetryPath),
            for: destinationLease.analyticsAttempt
        )
        analytics.record(
            source: .feedEngine,
            lifecycle: .handoffStarted,
            priority: .important,
            attempt: destinationLease.analyticsAttempt
        )
        destinationLease.phase = .focused
        destinationLease.hasStartedPlayback = false
        destinationLease.isAudible = true
        destination.lease = destinationLease
        activeItemID = destinationLease.itemID
        destination.session.setMuted(false)
        let hasPlatformPlayer = destination.session.feedPlatformPlayer != nil
        if hasPlatformPlayer {
            observeActivatedPlayback(in: destination, token: destinationLease.token)
        }
        destination.session.play()
        if !hasPlatformPlayer {
            confirmActivatedPlayback(in: destination, token: destinationLease.token)
        }
    }

    private func deactivateActivePlayback() {
        let previouslyActiveItemID = activeItemID
        for slot in slots {
            slot.session.setMuted(true)
            guard var lease = slot.lease else { continue }
            lease.isAudible = false
            if lease.itemID == previouslyActiveItemID {
                slot.session.pause()
                finishStallIfNeeded(in: &lease)
                if lease.phase == .focused { lease.phase = .warm }
                lease.hasStartedPlayback = false
            }
            slot.lease = lease
        }
        activeItemID = nil
        rebuildSnapshot()
    }

    private func observeActivatedPlayback(in slot: Slot, token: UUID) {
        guard let player = slot.session.feedPlatformPlayer else { return }
        slot.playbackStartObservation?.invalidate()
        slot.playbackStartObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self, weak slot] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor [weak self, weak slot] in
                guard let self, let slot else { return }
                self.confirmActivatedPlayback(in: slot, token: token)
            }
        }

        slot.playbackFailureObservation?.invalidate()
        guard let item = player.currentItem else { return }
        slot.playbackFailureObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak slot] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "AVPlayerItem failed"
            Task { @MainActor [weak self, weak slot] in
                guard let self, let slot else { return }
                self.failActivatedPlayback(in: slot, token: token, message: message)
            }
        }
    }

    private func confirmActivatedPlayback(in slot: Slot, token: UUID) {
        guard owns(slot, token: token),
              var lease = slot.lease,
              !isPlaybackSuspended,
              lease.itemID == activeItemID,
              lease.itemID == targetFocusedItemID,
              lease.generation == latestCoordinatorSnapshot?.generation,
              lease.isAudible
        else {
            return
        }
        lease.hasStartedPlayback = true
        slot.lease = lease
        slot.playbackStartObservation?.invalidate()
        slot.playbackStartObservation = nil
        if pendingFocus?.itemID == lease.itemID,
           pendingFocus?.generation == lease.generation {
            completePendingFocus(succeeded: true)
        }
        rebuildSnapshot()
    }

    private func failActivatedPlayback(in slot: Slot, token: UUID, message: String) {
        guard owns(slot, token: token), let lease = slot.lease else { return }
        acceptPlayerState(
            PlayerState(
                status: .failed(message),
                bufferDepthSeconds: lease.state.bufferDepthSeconds,
                qualityDescription: lease.state.qualityDescription,
                livePlayback: lease.state.livePlayback
            ),
            from: slot,
            token: token
        )
    }

    private func scheduleRelease(of slot: Slot) {
        guard slot.releaseTask == nil, let token = slot.lease?.token else { return }
        let grace = effectivePolicy.eviction.offscreenGracePeriod
        slot.releaseTask = Task { @MainActor [weak self, weak slot] in
            if grace > 0 {
                try? await Task.sleep(for: .seconds(grace))
            }
            guard !Task.isCancelled, let self, let slot,
                  self.owns(slot, token: token),
                  let itemID = slot.lease?.itemID,
                  !self.desiredItemIDs.contains(itemID)
            else { return }
            await self.release(
                slot,
                token: token,
                reconcilePreparedLeases: true
            )
        }
    }

    private func release(
        _ slot: Slot,
        token: UUID,
        reconcilePreparedLeases: Bool = false
    ) async {
        guard !slot.isReleasing,
              owns(slot, token: token),
              let itemID = slot.lease?.itemID
        else { return }
        slot.isReleasing = true
        let retiredPlatformPlayer = slot.session.feedPlatformPlayer
        slot.loadTask?.cancel()
        let loadTask = slot.loadTask
        let cancellationRequestedAt = loadTask.map { _ in telemetryClock.now() }
        var releasedLease = slot.lease
        if var releasedLeaseValue = releasedLease {
            finishStallIfNeeded(in: &releasedLeaseValue)
            releasedLease = releasedLeaseValue
        }
        let cancellationPath = releasedLease?.telemetryPath
        let analyticsAttempt = releasedLease?.analyticsAttempt
        slot.loadTask = nil
        let observationTask = slot.cancelLeaseObservers()
        let analyticsTasks = slot.cancelAnalyticsObservers()
        slot.session.setMuted(true)
        slot.session.pause()
        slotIDByItemID.removeValue(forKey: itemID)
        slot.lease = nil
        if activeItemID == itemID { activeItemID = nil }
        if pendingFocus?.itemID == itemID { completePendingFocus(succeeded: false) }
        if let loadTask {
            await loadTask.value
            if let cancellationRequestedAt, let cancellationPath {
                recordTelemetry(.init(
                    path: cancellationPath,
                    payload: .cancellation(
                        latency: Self.seconds(telemetryClock.now() - cancellationRequestedAt),
                        outcome: .acknowledged
                    )
                ), attempt: analyticsAttempt)
            }
        }
        await observationTask?.value
        for task in analyticsTasks { await task.value }
        await slot.session.stopAndWait()
        Self.silenceRetiredPlayer(retiredPlatformPlayer)
        if let analyticsAttempt {
            analytics.end(analyticsAttempt, lifecycle: .cancelled)
        }
        slot.releaseTask = nil
        slot.isReleasing = false
        rebuildSnapshot()
        if reconcilePreparedLeases, let latestCoordinatorSnapshot {
            acceptCoordinatorSnapshot(latestCoordinatorSnapshot)
        }
    }

    private func releaseAfterFailedLoad(
        _ slot: Slot,
        token: UUID,
        message: String
    ) async {
        guard !slot.isReleasing,
              owns(slot, token: token),
              var lease = slot.lease
        else { return }
        slot.isReleasing = true
        let retiredPlatformPlayer = slot.session.feedPlatformPlayer
        lease.phase = .failed(message)
        lease.state = PlayerState(status: .failed(message))
        slot.lease = lease
        failuresByItemID[lease.itemID] = .init(
            itemID: lease.itemID,
            generation: lease.generation,
            message: message
        )
        rebuildSnapshot()
        let observationTask = slot.cancelLeaseObservers()
        let analyticsTasks = slot.cancelAnalyticsObservers()
        slot.session.setMuted(true)
        slot.session.pause()
        slotIDByItemID.removeValue(forKey: lease.itemID)
        slot.lease = nil
        if activeItemID == lease.itemID { activeItemID = nil }
        if pendingFocus?.itemID == lease.itemID { completePendingFocus(succeeded: false) }
        await observationTask?.value
        for task in analyticsTasks { await task.value }
        await slot.session.stopAndWait()
        Self.silenceRetiredPlayer(retiredPlatformPlayer)
        analytics.end(lease.analyticsAttempt, lifecycle: .failed)
        slot.loadTask = nil
        slot.isReleasing = false
        rebuildSnapshot()
    }

    /// Teardown may reset native audio properties after the initial lease mute.
    /// Retained read-only player references must remain silent after retirement.
    private static func silenceRetiredPlayer(_ player: AVPlayer?) {
        player?.isMuted = true
        player?.volume = 0
        player?.pause()
        player?.cancelPendingPrerolls()
    }

    private func trimPoolIfNeeded() async {
        let limit = effectivePolicy.concurrency.maximumPlayerCount
        guard slots.count > limit else { return }
        let victims = slots.reversed()
            .filter { $0.lease?.itemID != activeItemID }
            .prefix(slots.count - limit)
        for slot in victims {
            while slot.isReleasing { await Task.yield() }
            if let token = slot.lease?.token {
                await release(slot, token: token)
            }
            while slot.isReleasing { await Task.yield() }
            slots.removeAll { $0.id == slot.id }
        }
        rebuildSnapshot()
    }

    private func installPlaybackEndObserver(for slot: Slot, token: UUID) {
        if let observer = slot.playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let item = slot.session.feedPlatformPlayer?.currentItem else {
            slot.playbackEndObserver = nil
            return
        }
        slot.playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak slot] _ in
            Task { @MainActor in
                guard let self, let slot, self.owns(slot, token: token) else { return }
                await self.playbackEnded(in: slot, token: token)
            }
        }
    }

    private func playbackEnded(in slot: Slot, token: UUID) async {
        guard owns(slot, token: token), let lease = slot.lease,
              !isPlaybackSuspended,
              lease.itemID == activeItemID,
              lease.isAudible
        else { return }
        switch effectivePolicy.looping {
        case .disabled:
            break
        case .focusedItem:
            await slot.session.restartPlayback()
        case .orderedCollection:
            guard let index = items.firstIndex(where: { $0.id == lease.itemID }),
                  !items.isEmpty
            else { return }
            requestedDestinationItemID = items[(index + 1) % items.count].id
            rebuildSnapshot()
        }
    }

    private func controlledItemID(_ requested: FeedItemID?) throws -> FeedItemID {
        if let requested { return requested }
        if let activeItemID { return activeItemID }
        if let targetFocusedItemID { return targetFocusedItemID }
        throw HLSFeedEngineError.noFocusedItem
    }

    private func owns(_ slot: Slot, token: UUID) -> Bool {
        slot.lease?.token == token
            && slot.lease.map { slotIDByItemID[$0.itemID] == slot.id } == true
    }

    private func slot(for itemID: FeedItemID) -> Slot? {
        guard let slotID = slotIDByItemID[itemID] else { return nil }
        return slots.first { $0.id == slotID }
    }

    private func recordStaleCompletion() {
        staleCompletionCount += 1
        rebuildSnapshot()
    }

    private func makePendingFocus(
        itemID: FeedItemID,
        generation: FeedNavigationGeneration
    ) -> PendingFocus {
        let item = itemsByID[itemID]
        let lease = slot(for: itemID)?.lease
        let wasReady: Bool
        if let lease {
            wasReady = lease.phase == .warm || lease.phase == .focused
        } else {
            wasReady = false
        }
        let reuse: HLSFeedTelemetry.Reuse = wasReady ? .warm : (lease?.telemetryPath.reuse ?? .cold)
        let source = item?.source ?? lease?.source
        let path = source.map {
            Self.telemetryPath(reuse: reuse, role: .focused, source: $0)
        } ?? HLSFeedTelemetry.Path(
            reuse: reuse,
            intent: .focused,
            mediaKind: .videoOnDemand
        )
        return PendingFocus(
            itemID: itemID,
            generation: generation,
            requestedAt: telemetryClock.now(),
            wasReadyAtRequest: wasReady,
            path: path
        )
    }

    private func completePendingFocus(succeeded: Bool) {
        guard let pendingFocus else { return }
        self.pendingFocus = nil
        recordPendingFocus(pendingFocus, succeeded: succeeded)
    }

    private func recordPendingFocus(_ pendingFocus: PendingFocus, succeeded: Bool) {
        let attempt = slot(for: pendingFocus.itemID)?.lease?.analyticsAttempt
        recordTelemetry(.init(
            path: pendingFocus.path,
            payload: .handoff(
                wasReady: pendingFocus.wasReadyAtRequest,
                succeeded: succeeded
            )
        ), attempt: attempt)
        if succeeded {
            recordTelemetry(.init(
                path: pendingFocus.path,
                payload: .firstFrame(latency: Self.seconds(
                    telemetryClock.now() - pendingFocus.requestedAt
                ))
            ), attempt: attempt)
        }
    }

    private func finishStallIfNeeded(in lease: inout Lease) {
        guard let stallStartedAt = lease.stallStartedAt else { return }
        recordTelemetry(.init(
            path: lease.telemetryPath,
            payload: .stall(duration: Self.seconds(telemetryClock.now() - stallStartedAt))
        ), attempt: lease.analyticsAttempt)
        lease.stallStartedAt = nil
    }

    private func ingestCancellationMetrics(from value: FeedCoordinatorSnapshot) {
        let acknowledgements = max(
            0,
            value.cancellationAcknowledgementCount - latestCancellationAcknowledgementCount
        )
        let late = min(
            acknowledgements,
            max(0, value.lateCancellationCount - latestLateCancellationCount)
        )
        let acknowledgedOnTime = acknowledgements - late
        guard acknowledgements > 0 else {
            latestCancellationAcknowledgementCount = value.cancellationAcknowledgementCount
            latestLateCancellationCount = value.lateCancellationCount
            return
        }
        let latency = value.maximumCancellationLatency.map(Self.seconds) ?? 0
        let path = cancellationTelemetryPath()
        let attempt = targetFocusedItemID.flatMap { slot(for: $0)?.lease?.analyticsAttempt }
            ?? activeItemID.flatMap { slot(for: $0)?.lease?.analyticsAttempt }
        for _ in 0..<acknowledgedOnTime {
            recordTelemetry(.init(
                path: path,
                payload: .cancellation(latency: latency, outcome: .acknowledged)
            ), attempt: attempt)
        }
        for _ in 0..<late {
            recordTelemetry(.init(
                path: path,
                payload: .cancellation(latency: latency, outcome: .late)
            ), attempt: attempt)
        }
        latestCancellationAcknowledgementCount = value.cancellationAcknowledgementCount
        latestLateCancellationCount = value.lateCancellationCount
    }

    private func cancellationTelemetryPath() -> HLSFeedTelemetry.Path {
        if let targetFocusedItemID,
           let lease = slot(for: targetFocusedItemID)?.lease {
            return Self.telemetryPath(
                reuse: lease.telemetryPath.reuse,
                role: .predicted,
                source: lease.source
            )
        }
        if let targetFocusedItemID, let item = itemsByID[targetFocusedItemID] {
            return Self.telemetryPath(
                reuse: .cold,
                role: .predicted,
                source: item.source
            )
        }
        return HLSFeedTelemetry.Path(
            reuse: .cold,
            intent: .predicted,
            mediaKind: .videoOnDemand
        )
    }

    private func scheduleCacheSample() {
        guard let sharedCache, cacheSampleTask == nil, !isStopped else { return }
        cacheSampleTask = Task { @MainActor [weak self] in
            let value = await sharedCache.metrics()
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.cacheMetrics = value
            self.cacheSampleTask = nil
            self.recordResourceSample()
        }
    }

    private func recordResourceSample() {
        let event = HLSFeedTelemetry.Event(payload: .resources(
            memoryBytes: cacheMetrics.totalBytes,
            diskBytes: cacheMetrics.diskBytes,
            playerPoolOccupancy: slotIDByItemID.count,
            proxyPoolOccupancy: slots.count
        ))
        let attempt = activeItemID.flatMap { slot(for: $0)?.lease?.analyticsAttempt }
            ?? targetFocusedItemID.flatMap { slot(for: $0)?.lease?.analyticsAttempt }
            ?? slots.compactMap({ $0.lease?.analyticsAttempt }).first
        recordTelemetry(event, attempt: attempt)
        let evictionCounts = cacheMetrics.evictionCounts.reduce(into: [
            HLSFeedTelemetry.CacheEvictionReason: Int
        ]()) { result, entry in
            guard let reason = HLSFeedTelemetry.CacheEvictionReason(
                rawValue: entry.key.rawValue
            ) else { return }
            result[reason] = entry.value
        }
        recordTelemetry(.init(payload: .cacheResources(
            memoryEntryCount: cacheMetrics.memoryEntryCount,
            diskEntryCount: cacheMetrics.diskEntryCount,
            evictionCounts: evictionCounts
        )), attempt: attempt)
    }

    private func recordTelemetry(
        _ event: HLSFeedTelemetry.Event,
        attempt: PlaybackAnalyticsTimeline.Attempt?
    ) {
        telemetry.record(event)
        if let attempt {
            analytics.record(feed: event, attempt: attempt)
        }
    }

    private func recordPlaybackLifecycle(_ lifecycle: PlaybackAnalytics.Lifecycle) {
        let attempt = activeItemID.flatMap { slot(for: $0)?.lease?.analyticsAttempt }
            ?? targetFocusedItemID.flatMap { slot(for: $0)?.lease?.analyticsAttempt }
        guard let attempt else { return }
        analytics.record(
            source: .feedEngine,
            lifecycle: lifecycle,
            priority: .important,
            attempt: attempt
        )
    }

    private func rebuildSnapshot() {
        let itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        let playbacks = slots.compactMap(\.lease).sorted { lhs, rhs in
            let lhsIndex = itemIndices[lhs.itemID] ?? Int.max
            let rhsIndex = itemIndices[rhs.itemID] ?? Int.max
            if lhsIndex == rhsIndex { return lhs.itemID.rawValue < rhs.itemID.rawValue }
            return lhsIndex < rhsIndex
        }.map { lease in
            HLSFeedPlayback(
                itemID: lease.itemID,
                generation: lease.generation,
                role: lease.role,
                phase: lease.phase,
                state: lease.state,
                hasStartedPlayback: lease.hasStartedPlayback,
                isAudible: lease.isAudible
            )
        }
        let audibleItemIDs = playbacks.filter(\.isAudible).map(\.itemID)
        maximumObservedAudiblePlaybackCount = max(
            maximumObservedAudiblePlaybackCount,
            audibleItemIDs.count
        )
        let activeLoads = slots.reduce(into: 0) { count, slot in
            if slot.loadTask != nil { count += 1 }
        }
        // Preparation can fail before a player lease exists (for example an
        // offline cold-cache miss). Surface those failures without retaining
        // them beyond the coordinator's current bounded working set.
        var reportedFailures = failuresByItemID
        if let coordinator = latestCoordinatorSnapshot, let generation = coordinator.generation {
            for entry in coordinator.entries {
                guard case .failed(let message) = entry.status else { continue }
                reportedFailures[entry.itemID] = .init(
                    itemID: entry.itemID, generation: generation, message: message
                )
            }
        }
        snapshot = HLSFeedEngineSnapshot(
            generation: latestCoordinatorSnapshot?.generation,
            targetFocusedItemID: targetFocusedItemID,
            activeItemID: activeItemID,
            audibleItemID: audibleItemIDs.count == 1 ? audibleItemIDs[0] : nil,
            requestedDestinationItemID: requestedDestinationItemID,
            playbacks: playbacks,
            failures: reportedFailures.values.sorted { lhs, rhs in
                let lhsIndex = itemIndices[lhs.itemID] ?? Int.max
                let rhsIndex = itemIndices[rhs.itemID] ?? Int.max
                if lhsIndex == rhsIndex { return lhs.itemID.rawValue < rhs.itemID.rawValue }
                return lhsIndex < rhsIndex
            },
            poolOccupancy: slotIDByItemID.count,
            allocatedPlayerCount: slots.count,
            activeLoadCount: activeLoads,
            maximumObservedPoolOccupancy: maximumObservedPoolOccupancy,
            maximumObservedAudiblePlaybackCount: maximumObservedAudiblePlaybackCount,
            staleCompletionCount: staleCompletionCount,
            isPlaybackSuspended: isPlaybackSuspended
        )
        recordResourceSample()
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private static func telemetryPath(
        reuse: HLSFeedTelemetry.Reuse,
        role: FeedPlan.Role,
        source: FeedPlaybackSource
    ) -> HLSFeedTelemetry.Path {
        let intent: HLSFeedTelemetry.Intent = role == .focused ? .focused : .predicted
        let mediaKind: HLSFeedTelemetry.MediaKind = switch source {
        case .stream(_, .live): .live
        case .compatibleClips: .stitched
        case .stream(_, .videoOnDemand), .clips: .videoOnDemand
        }
        return HLSFeedTelemetry.Path(reuse: reuse, intent: intent, mediaKind: mediaKind)
    }

    private static func analyticsAttribution(
        from path: HLSFeedTelemetry.Path
    ) -> PlaybackAnalyticsTimeline.Attribution {
        let reuse: PlaybackAnalyticsTimeline.Reuse = path.reuse == .warm ? .warm : .cold
        let intent: PlaybackAnalyticsTimeline.Intent = path.intent == .focused
            ? .focused
            : .predicted
        let mediaKind: PlaybackAnalyticsTimeline.MediaKind = switch path.mediaKind {
        case .videoOnDemand: .videoOnDemand
        case .live: .live
        case .stitched: .stitched
        }
        return .init(reuse: reuse, intent: intent, mediaKind: mediaKind)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        )
    }

    private static func validatedItemsByID(
        _ items: [FeedPlaybackItem]
    ) throws -> [FeedItemID: FeedPlaybackItem] {
        var result: [FeedItemID: FeedPlaybackItem] = [:]
        for item in items {
            guard !item.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeedPlanningError.emptyItemID
            }
            guard result[item.id] == nil else {
                throw FeedPlanningError.duplicateItemID(item.id)
            }
            guard !item.source.hasEmptyClipSequence else {
                throw FeedPlanningError.emptyClipSequence(item.id)
            }
            result[item.id] = item
        }
        return result
    }

    private static func playerConfiguration(
        for policy: FeedPlaybackPolicy,
        sourceTransportPolicy: HLSFeedSourceTransportPolicy
    ) throws -> ProxyPlayerConfiguration {
        var configuration = try policy.makeProxyPlayerConfiguration()
        configuration.allowInsecureManifests = sourceTransportPolicy.allowsInsecureManifests
        if configuration.cachePolicy.enableDiskCache,
           configuration.cachePolicy.diskDirectory == nil {
            configuration.cachePolicy.diskDirectory = defaultFeedCacheDirectory()
        }
        return configuration
    }

    private static func validateSourceURLs(
        in items: [FeedPlaybackItem],
        policy: HLSFeedSourceTransportPolicy
    ) throws {
        for item in items {
            let urls: [URL] = switch item.source {
            case .stream(let url, _): [url]
            case .clips(let urls): urls
            case .compatibleClips(let clips): clips.map(\.playlistURL)
            }
            if let url = urls.first(where: { !policy.allows($0) }) {
                throw HLSFeedEngineError.disallowedSourceURL(url)
            }
        }
    }

    private static func makeSharedCache(policy: FeedPlaybackPolicy) -> HLSSegmentCache {
        let diskDirectory = policy.eviction.usesDiskCache
            ? (policy.eviction.diskDirectory ?? defaultFeedCacheDirectory())
            : nil
        return HLSSegmentCache(
            capacityBytes: policy.budget.memoryCacheBytes,
            diskDirectory: diskDirectory,
            diskCapacityBytes: policy.budget.diskCacheBytes,
            timeToLive: policy.eviction.timeToLive,
            maximumEntryCount: policy.budget.maximumCacheEntryCount
        )
    }

    private static func defaultFeedCacheDirectory() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("HLSProxyBuffer", isDirectory: true)
            .appendingPathComponent("FeedPreparation", isDirectory: true)
    }
}
