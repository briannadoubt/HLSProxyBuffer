import Foundation
import Observation
import ProxyPlayerKit

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

#if canImport(Network)
import Network
#endif

enum FeedDemoBackgroundTaskKind: String, CaseIterable, Codable, Sendable {
    case refresh
    case processing
}

enum FeedDemoApplicationPhase: Equatable, Sendable {
    case active
    case inactive
    case background
}

struct FeedDemoBackgroundScheduleRequest: Equatable, Sendable {
    let kind: FeedDemoBackgroundTaskKind
    let earliestBeginDate: Date
    let requiresNetworkConnectivity: Bool
    let requiresExternalPower: Bool
}

@MainActor
protocol FeedDemoBackgroundScheduling: AnyObject {
    func submit(_ request: FeedDemoBackgroundScheduleRequest) throws
    func cancel(_ kind: FeedDemoBackgroundTaskKind)
}

@MainActor
protocol FeedDemoBackgroundEnvironmentProviding: AnyObject {
    var current: HLSFeedBackgroundEnvironment { get }
}

struct FeedDemoBackgroundSchedulePolicy: Equatable, Sendable {
    static let shortFormFeed = Self(
        refreshDelay: 15 * 60,
        processingDelay: 60 * 60,
        refreshExecutionTime: .seconds(15),
        processingExecutionTime: .seconds(15)
    )

    let refreshDelay: TimeInterval
    let processingDelay: TimeInterval
    let refreshExecutionTime: Duration
    let processingExecutionTime: Duration

    func request(
        for kind: FeedDemoBackgroundTaskKind,
        now: Date
    ) -> FeedDemoBackgroundScheduleRequest {
        FeedDemoBackgroundScheduleRequest(
            kind: kind,
            earliestBeginDate: now.addingTimeInterval(
                kind == .refresh ? refreshDelay : processingDelay
            ),
            requiresNetworkConnectivity: kind == .processing,
            requiresExternalPower: false
        )
    }

    func executionTime(for kind: FeedDemoBackgroundTaskKind) -> Duration {
        kind == .refresh ? refreshExecutionTime : processingExecutionTime
    }
}

struct FeedDemoBackgroundLifecycleSnapshot: Equatable, Codable, Sendable {
    enum Event: String, CaseIterable, Codable, Sendable {
        case registered
        case registrationDenied
        case scheduled
        case admitted
        case completed
        case expired
        case cancelled
        case systemDenied
        case policyDenied
        case failed
    }

    struct EventCount: Equatable, Codable, Sendable {
        let event: Event
        let count: UInt64
    }

    static let empty = Self(
        events: Event.allCases.map { .init(event: $0, count: 0) },
        maximumCandidateCount: 0,
        maximumAdmittedItemCount: 0,
        activeTaskKind: nil
    )

    let events: [EventCount]
    let maximumCandidateCount: Int
    let maximumAdmittedItemCount: Int
    let activeTaskKind: FeedDemoBackgroundTaskKind?

    func count(for event: Event) -> UInt64 {
        events.first { $0.event == event }?.count ?? 0
    }
}

struct FeedDemoBackgroundWorkResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        case expired
        case cancelled
        case policyDenied
        case failed
    }

    let outcome: Outcome
    let admittedItemCount: Int

    init(outcome: Outcome, admittedItemCount: Int) {
        self.outcome = outcome
        self.admittedItemCount = admittedItemCount
    }

    init(_ result: HLSFeedBackgroundWarmingResult) {
        admittedItemCount = result.admittedItemCount
        outcome = switch result.outcome {
        case .completed, .completedWithFailures, .noEligibleWork:
            .completed
        case .expired:
            .expired
        case .cancelled:
            .cancelled
        case .deniedBusy, .deniedLowPower, .deniedOffline, .deniedCellular,
                .deniedConstrained, .deniedExpensive:
            .policyDenied
        case .failed:
            .failed
        }
    }
}

/// Testable lifecycle ledger and scheduler facade for the demo host.
///
/// The engine remains the sole owner of players, buffers, cache, admission, and
/// network policy. This type only translates application lifecycle and
/// system-granted opportunities into bounded engine calls.
@Observable
@MainActor
final class FeedDemoBackgroundLifecycle {
    private enum Termination: Equatable {
        case expired
        case cancelled
    }

    private struct ActiveRun {
        let id: UUID
        let kind: FeedDemoBackgroundTaskKind
        let task: Task<FeedDemoBackgroundWorkResult, Error>
        var termination: Termination?
    }

    private(set) var snapshot = FeedDemoBackgroundLifecycleSnapshot.empty

    @ObservationIgnored private let scheduler: any FeedDemoBackgroundScheduling
    @ObservationIgnored private let policy: FeedDemoBackgroundSchedulePolicy
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var counts = Dictionary(
        uniqueKeysWithValues: FeedDemoBackgroundLifecycleSnapshot.Event.allCases.map {
            ($0, UInt64(0))
        }
    )
    @ObservationIgnored private var maximumCandidateCount = 0
    @ObservationIgnored private var maximumAdmittedItemCount = 0
    @ObservationIgnored private var activeRun: ActiveRun?

    init(
        scheduler: any FeedDemoBackgroundScheduling,
        policy: FeedDemoBackgroundSchedulePolicy = .shortFormFeed,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.policy = policy
        self.now = now
    }

    func recordRegistration(
        _ kind: FeedDemoBackgroundTaskKind,
        accepted: Bool
    ) {
        _ = kind
        record(accepted ? .registered : .registrationDenied)
    }

    func scheduleAll() {
        for kind in FeedDemoBackgroundTaskKind.allCases {
            schedule(kind)
        }
    }

    func schedule(_ kind: FeedDemoBackgroundTaskKind) {
        do {
            try scheduler.submit(policy.request(for: kind, now: now()))
            record(.scheduled)
        } catch {
            record(.systemDenied)
        }
    }

    func cancelPending() {
        for kind in FeedDemoBackgroundTaskKind.allCases {
            scheduler.cancel(kind)
        }
    }

    func run(
        kind: FeedDemoBackgroundTaskKind,
        request: HLSFeedBackgroundWarmingRequest,
        cancellationIsExpiration: Bool = true,
        operation: @escaping @MainActor () async throws -> FeedDemoBackgroundWorkResult
    ) async -> Bool {
        cancelActive(reason: .cancelled)
        record(.admitted)
        maximumCandidateCount = max(maximumCandidateCount, request.candidates.count)

        let id = UUID()
        let task = Task { @MainActor in
            try await operation()
        }
        activeRun = ActiveRun(id: id, kind: kind, task: task, termination: nil)
        publishSnapshot()

        let result: Result<FeedDemoBackgroundWorkResult, Error> = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }

        guard let run = activeRun, run.id == id else {
            return false
        }
        activeRun = nil

        switch result {
        case .success(let work):
            maximumAdmittedItemCount = max(
                maximumAdmittedItemCount,
                work.admittedItemCount
            )
            switch work.outcome {
            case .completed:
                record(.completed)
                return true
            case .expired:
                record(.expired)
            case .cancelled:
                record(terminationEvent(
                    for: run,
                    cancellationIsExpiration: cancellationIsExpiration
                ))
            case .policyDenied:
                record(.policyDenied)
                return true
            case .failed:
                record(.failed)
            }
        case .failure(let error):
            if error is CancellationError {
                record(terminationEvent(
                    for: run,
                    cancellationIsExpiration: cancellationIsExpiration
                ))
            } else {
                record(.failed)
            }
        }
        return false
    }

    func expire(_ kind: FeedDemoBackgroundTaskKind) {
        guard activeRun?.kind == kind else { return }
        cancelActive(reason: .expired)
    }

    func cancelActive() {
        cancelActive(reason: .cancelled)
    }

    func executionTime(for kind: FeedDemoBackgroundTaskKind) -> Duration {
        policy.executionTime(for: kind)
    }

    func machineReadableSummary() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    private func cancelActive(reason: Termination) {
        guard var run = activeRun else { return }
        run.termination = reason
        activeRun = nil
        run.task.cancel()
        record(reason == .expired ? .expired : .cancelled)
    }

    private func terminationEvent(
        for run: ActiveRun,
        cancellationIsExpiration: Bool
    ) -> FeedDemoBackgroundLifecycleSnapshot.Event {
        if run.termination == .expired { return .expired }
        if run.termination == nil, Task.isCancelled, cancellationIsExpiration {
            return .expired
        }
        return .cancelled
    }

    private func record(_ event: FeedDemoBackgroundLifecycleSnapshot.Event) {
        counts[event] = (counts[event] ?? 0) &+ 1
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshot = FeedDemoBackgroundLifecycleSnapshot(
            events: FeedDemoBackgroundLifecycleSnapshot.Event.allCases.map {
                .init(event: $0, count: counts[$0] ?? 0)
            },
            maximumCandidateCount: maximumCandidateCount,
            maximumAdmittedItemCount: maximumAdmittedItemCount,
            activeTaskKind: activeRun?.kind
        )
    }
}

@MainActor
final class FeedDemoUnavailableBackgroundScheduler: FeedDemoBackgroundScheduling {
    struct Unavailable: Error {}

    func submit(_ request: FeedDemoBackgroundScheduleRequest) throws {
        _ = request
        throw Unavailable()
    }

    func cancel(_ kind: FeedDemoBackgroundTaskKind) {
        _ = kind
    }
}

@MainActor
final class FeedDemoStaticBackgroundEnvironment: FeedDemoBackgroundEnvironmentProviding {
    var current: HLSFeedBackgroundEnvironment

    init(current: HLSFeedBackgroundEnvironment) {
        self.current = current
    }
}

@MainActor
enum FeedDemoBackgroundDependencies {
    static func makeScheduler() -> any FeedDemoBackgroundScheduling {
#if canImport(BackgroundTasks) && os(iOS)
        FeedDemoSystemBackgroundScheduler.shared
#else
        FeedDemoUnavailableBackgroundScheduler()
#endif
    }

    static func makeEnvironmentProvider() -> any FeedDemoBackgroundEnvironmentProviding {
#if canImport(Network)
        FeedDemoSystemBackgroundEnvironment()
#else
        FeedDemoStaticBackgroundEnvironment(
            current: .init(networkInterface: .unavailable)
        )
#endif
    }
}

#if canImport(Network)
@MainActor
final class FeedDemoSystemBackgroundEnvironment: FeedDemoBackgroundEnvironmentProviding {
    private(set) var current = HLSFeedBackgroundEnvironment(networkInterface: .unavailable)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "HLSProxyFeedDemo.NetworkPath")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let environment = Self.environment(from: path)
            Task { @MainActor [weak self] in
                self?.current = environment
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private nonisolated static func environment(
        from path: NWPath
    ) -> HLSFeedBackgroundEnvironment {
        let networkInterface: HLSFeedBackgroundEnvironment.NetworkInterface
        if path.status != .satisfied {
            networkInterface = .unavailable
        } else if path.usesInterfaceType(.wifi) {
            networkInterface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            networkInterface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            networkInterface = .wired
        } else {
            networkInterface = .other
        }
        return HLSFeedBackgroundEnvironment(
            networkInterface: networkInterface,
            isConstrained: path.isConstrained,
            isExpensive: path.isExpensive,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}
#endif

#if canImport(BackgroundTasks) && os(iOS)
enum FeedDemoBackgroundTaskIdentifiers {
    static let refresh = "com.hlsproxybuffer.feed-demo.refresh"
    static let processing = "com.hlsproxybuffer.feed-demo.processing"

    static func identifier(for kind: FeedDemoBackgroundTaskKind) -> String {
        kind == .refresh ? refresh : processing
    }
}

@MainActor
final class FeedDemoSystemBackgroundScheduler: FeedDemoBackgroundScheduling {
    static let shared = FeedDemoSystemBackgroundScheduler()

    private init() {}

    func submit(_ request: FeedDemoBackgroundScheduleRequest) throws {
        let taskRequest: BGTaskRequest
        switch request.kind {
        case .refresh:
            taskRequest = BGAppRefreshTaskRequest(
                identifier: FeedDemoBackgroundTaskIdentifiers.refresh
            )
        case .processing:
            let processing = BGProcessingTaskRequest(
                identifier: FeedDemoBackgroundTaskIdentifiers.processing
            )
            processing.requiresNetworkConnectivity = request.requiresNetworkConnectivity
            processing.requiresExternalPower = request.requiresExternalPower
            taskRequest = processing
        }
        taskRequest.earliestBeginDate = request.earliestBeginDate
        try BGTaskScheduler.shared.submit(taskRequest)
    }

    func cancel(_ kind: FeedDemoBackgroundTaskKind) {
        BGTaskScheduler.shared.cancel(
            taskRequestWithIdentifier: FeedDemoBackgroundTaskIdentifiers.identifier(for: kind)
        )
    }
}
#endif
