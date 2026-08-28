import Foundation
import HLSCore

/// A small, validated cap set for opportunistic feed warming.
///
/// This policy bounds one background invocation. It does not schedule work;
/// Apple platforms decide whether and when a submitted background task runs.
public struct HLSFeedBackgroundWarmingPolicy: Sendable, Equatable {
    public enum PrivacyPolicy: String, CaseIterable, Codable, Sendable {
        /// Metrics contain fixed-cardinality counts only. Item IDs, URLs,
        /// application metadata, and error strings are never retained.
        case aggregateOnly
    }

    public enum ValidationIssue: String, CaseIterable, Sendable {
        case itemLimitMustBePositive
        case segmentLimitMustBePositive
        case byteLimitMustBePositive
        case concurrencyLimitMustBePositive
        case executionTimeMustBePositive
        case cacheValidityMustBeNonnegative
    }

    public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
        public let issues: [ValidationIssue]

        public var errorDescription: String? {
            "Invalid background warming policy: " + issues.map(\.rawValue).joined(separator: ", ")
        }
    }

    public static let shortFormFeed = Self(
        maximumItemCount: 2,
        maximumLeadingSegmentsPerItem: 1,
        maximumEstimatedByteCount: 4 * 1_024 * 1_024,
        maximumConcurrentPreparations: 1,
        maximumExecutionTime: .seconds(15),
        minimumRemainingCacheValidity: .seconds(30),
        allowsCellularAccess: false,
        allowsConstrainedNetworkAccess: false,
        allowsExpensiveNetworkAccess: false,
        allowsLowPowerMode: false,
        privacy: .aggregateOnly
    )

    public var maximumItemCount: Int
    public var maximumLeadingSegmentsPerItem: Int
    /// A conservative admission reservation supplied by each feed item.
    /// Actual cache and origin bytes are reported separately.
    public var maximumEstimatedByteCount: Int
    public var maximumConcurrentPreparations: Int
    public var maximumExecutionTime: Duration
    /// Fresh entries with at least this much validity remaining need no work.
    public var minimumRemainingCacheValidity: Duration
    public var allowsCellularAccess: Bool
    public var allowsConstrainedNetworkAccess: Bool
    public var allowsExpensiveNetworkAccess: Bool
    public var allowsLowPowerMode: Bool
    public var privacy: PrivacyPolicy

    public init(
        maximumItemCount: Int,
        maximumLeadingSegmentsPerItem: Int,
        maximumEstimatedByteCount: Int,
        maximumConcurrentPreparations: Int,
        maximumExecutionTime: Duration,
        minimumRemainingCacheValidity: Duration,
        allowsCellularAccess: Bool,
        allowsConstrainedNetworkAccess: Bool,
        allowsExpensiveNetworkAccess: Bool,
        allowsLowPowerMode: Bool,
        privacy: PrivacyPolicy = .aggregateOnly
    ) {
        self.maximumItemCount = maximumItemCount
        self.maximumLeadingSegmentsPerItem = maximumLeadingSegmentsPerItem
        self.maximumEstimatedByteCount = maximumEstimatedByteCount
        self.maximumConcurrentPreparations = maximumConcurrentPreparations
        self.maximumExecutionTime = maximumExecutionTime
        self.minimumRemainingCacheValidity = minimumRemainingCacheValidity
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsLowPowerMode = allowsLowPowerMode
        self.privacy = privacy
    }

    public var validationIssues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if maximumItemCount < 1 { issues.append(.itemLimitMustBePositive) }
        if maximumLeadingSegmentsPerItem < 1 { issues.append(.segmentLimitMustBePositive) }
        if maximumEstimatedByteCount < 1 { issues.append(.byteLimitMustBePositive) }
        if maximumConcurrentPreparations < 1 {
            issues.append(.concurrencyLimitMustBePositive)
        }
        if maximumExecutionTime <= .zero { issues.append(.executionTimeMustBePositive) }
        if minimumRemainingCacheValidity < .zero {
            issues.append(.cacheValidityMustBeNonnegative)
        }
        return issues
    }

    public func validated() throws -> Self {
        let issues = validationIssues
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
        return self
    }
}

/// Current system conditions supplied by a UI-independent platform adapter.
public struct HLSFeedBackgroundEnvironment: Sendable, Equatable {
    public enum NetworkInterface: String, CaseIterable, Codable, Sendable {
        case unavailable
        case wifi
        case cellular
        case wired
        case other
    }

    public var networkInterface: NetworkInterface
    public var isConstrained: Bool
    public var isExpensive: Bool
    public var isLowPowerModeEnabled: Bool

    public init(
        networkInterface: NetworkInterface,
        isConstrained: Bool = false,
        isExpensive: Bool = false,
        isLowPowerModeEnabled: Bool = false
    ) {
        self.networkInterface = networkInterface
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }
}

/// One ordered candidate and the engine-owned cache fact known at scheduling.
public struct HLSFeedBackgroundWarmingCandidate: Sendable, Equatable {
    public enum CacheState: Sendable, Equatable {
        case absent
        case unknown
        case stale
        case fresh(remainingValidity: Duration)
    }

    public let item: FeedPlaybackItem
    public let cacheState: CacheState

    public init(item: FeedPlaybackItem, cacheState: CacheState = .unknown) {
        self.item = item
        self.cacheState = cacheState
    }
}

/// A platform task's bounded opportunity to warm an ordered predicted set.
public struct HLSFeedBackgroundWarmingRequest: Sendable, Equatable {
    public let candidates: [HLSFeedBackgroundWarmingCandidate]
    public let environment: HLSFeedBackgroundEnvironment
    /// Remaining time granted by the platform adapter. The policy applies its
    /// own smaller ceiling. A nonpositive value is already expired.
    public let availableExecutionTime: Duration

    public init(
        candidates: [HLSFeedBackgroundWarmingCandidate],
        environment: HLSFeedBackgroundEnvironment,
        availableExecutionTime: Duration
    ) {
        self.candidates = candidates
        self.environment = environment
        self.availableExecutionTime = availableExecutionTime
    }
}

public struct HLSFeedBackgroundWarmingClock: Sendable {
    public static let continuous = Self { duration in
        try await ContinuousClock().sleep(for: duration)
    }

    private let sleeper: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleeper = sleep
    }

    fileprivate func sleep(for duration: Duration) async throws {
        try await sleeper(duration)
    }
}

public enum HLSFeedBackgroundWarmingError: Error, Equatable, LocalizedError, Sendable {
    case busy

    public var errorDescription: String? {
        "Background warming policy cannot change while a request is running"
    }
}

/// A fixed-cardinality, privacy-safe record of background warming outcomes.
public struct HLSFeedBackgroundWarmingSnapshot: Equatable, Codable, Sendable {
    public enum Outcome: String, CaseIterable, Codable, Sendable {
        case completed
        case completedWithFailures
        case noEligibleWork
        case deniedBusy
        case deniedLowPower
        case deniedOffline
        case deniedCellular
        case deniedConstrained
        case deniedExpensive
        case expired
        case cancelled
        case failed
    }

    public struct OutcomeCount: Equatable, Codable, Sendable {
        public let outcome: Outcome
        public let count: UInt64
    }

    public let requestCount: UInt64
    public let admittedRequestCount: UInt64
    public let outcomes: [OutcomeCount]
    public let candidateItemCount: UInt64
    public let admittedItemCount: UInt64
    public let preparedItemCount: UInt64
    public let failedItemCount: UInt64
    public let skippedFreshCacheItemCount: UInt64
    public let skippedBudgetItemCount: UInt64
    public let preparedLeadingSegmentCount: UInt64
    public let preparedResourceCount: UInt64
    public let preparedByteCount: UInt64
    public let cacheHitCount: UInt64
    public let originFetchCount: UInt64
    public let cacheHitByteCount: UInt64
    public let originFetchByteCount: UInt64
    public let maximumObservedConcurrentPreparations: Int
    public let maximumOutcomeCardinality: Int

    public func count(for outcome: Outcome) -> UInt64 {
        outcomes.first { $0.outcome == outcome }?.count ?? 0
    }
}

public struct HLSFeedBackgroundWarmingResult: Equatable, Sendable {
    public let outcome: HLSFeedBackgroundWarmingSnapshot.Outcome
    public let candidateItemCount: Int
    public let admittedItemCount: Int
    public let preparedItemCount: Int
    public let failedItemCount: Int
    public let skippedFreshCacheItemCount: Int
    public let skippedBudgetItemCount: Int
    public let admittedEstimatedByteCount: Int
    public let preparedLeadingSegmentCount: Int
    public let preparedResourceCount: Int
    public let preparedByteCount: Int
    public let cacheHitCount: Int
    public let originFetchCount: Int
    public let cacheHitByteCount: Int
    public let originFetchByteCount: Int
    public let maximumConcurrentPreparationCount: Int
}

/// Player-free, cancellation-cooperative warming for an engine-owned feed cache.
///
/// Callers pass typed platform conditions and predicted items. This actor owns
/// admission, concurrency, timeout, preparation, and sanitized metrics. It
/// never constructs an AVPlayer and permits only one invocation at a time.
public actor HLSFeedBackgroundWarmer {
    private struct Selection: Sendable {
        let candidates: [HLSFeedBackgroundWarmingCandidate]
        let freshSkipCount: Int
        let budgetSkipCount: Int
        let estimatedByteCount: Int
    }

    private struct Batch: Sendable {
        var preparedItemCount = 0
        var failedItemCount = 0
        var cancelledItemCount = 0
        var leadingSegmentCount = 0
        var resourceCount = 0
        var byteCount = 0
        var cacheHitCount = 0
        var originFetchCount = 0
        var cacheHitByteCount = 0
        var originFetchByteCount = 0
        var maximumConcurrency = 0

        mutating func add(_ prepared: FeedPreparedItem) {
            preparedItemCount += 1
            leadingSegmentCount += prepared.leadingSegmentCount
            resourceCount += prepared.preparedResourceCount
            byteCount += prepared.preparedByteCount
            cacheHitCount += prepared.cacheHitCount
            originFetchCount += prepared.originFetchCount
            cacheHitByteCount += prepared.cacheHitByteCount
            originFetchByteCount += prepared.originFetchByteCount
        }
    }

    private enum ItemOutcome: Sendable {
        case prepared(FeedPreparedItem)
        case failed
        case cancelled
    }

    private enum RaceOutcome: Sendable {
        case batch(Batch)
        case expired(Batch)
        case cancelled(Batch)
    }

    private var policy: HLSFeedBackgroundWarmingPolicy
    private let backend: any FeedPreparing
    private let clock: HLSFeedBackgroundWarmingClock
    private var nextGeneration: UInt64 = 0
    private var isRunning = false
    private var outcomeCounts: [HLSFeedBackgroundWarmingSnapshot.Outcome: UInt64] = Dictionary(
        uniqueKeysWithValues: HLSFeedBackgroundWarmingSnapshot.Outcome.allCases.map { ($0, 0) }
    )
    private var requestCount: UInt64 = 0
    private var admittedRequestCount: UInt64 = 0
    private var candidateItemCount: UInt64 = 0
    private var admittedItemCount: UInt64 = 0
    private var preparedItemCount: UInt64 = 0
    private var failedItemCount: UInt64 = 0
    private var skippedFreshCacheItemCount: UInt64 = 0
    private var skippedBudgetItemCount: UInt64 = 0
    private var preparedLeadingSegmentCount: UInt64 = 0
    private var preparedResourceCount: UInt64 = 0
    private var preparedByteCount: UInt64 = 0
    private var cacheHitCount: UInt64 = 0
    private var originFetchCount: UInt64 = 0
    private var cacheHitByteCount: UInt64 = 0
    private var originFetchByteCount: UInt64 = 0
    private var maximumObservedConcurrentPreparations = 0
    private var continuations: [
        UUID: AsyncStream<HLSFeedBackgroundWarmingSnapshot>.Continuation
    ] = [:]

    public init(
        policy: HLSFeedBackgroundWarmingPolicy = .shortFormFeed,
        backend: any FeedPreparing,
        clock: HLSFeedBackgroundWarmingClock = .continuous
    ) throws {
        self.policy = try policy.validated()
        self.backend = backend
        self.clock = clock
    }

    /// Creates the production, cache-sharing preparation path without players.
    public init(
        feedPolicy: FeedPlaybackPolicy,
        policy: HLSFeedBackgroundWarmingPolicy = .shortFormFeed,
        sourceTransportPolicy: HLSFeedSourceTransportPolicy = .secureOnly,
        clock: HLSFeedBackgroundWarmingClock = .continuous
    ) throws {
        let validated = try policy.validated()
        let backendPolicy = try Self.backendPolicy(
            from: feedPolicy,
            warmingPolicy: validated
        )
        self.policy = validated
        self.backend = try HLSFeedPreparationBackend(
            policy: backendPolicy,
            allowsInsecureManifests: sourceTransportPolicy.allowsInsecureManifests
        )
        self.clock = clock
    }

    public func updatePolicy(_ policy: HLSFeedBackgroundWarmingPolicy) async throws {
        let validated = try policy.validated()
        guard !isRunning else { throw HLSFeedBackgroundWarmingError.busy }
        self.policy = validated
    }

    public func snapshot() -> HLSFeedBackgroundWarmingSnapshot {
        snapshotValue()
    }

    /// Newest-only observation with bounded subscriber storage.
    public func updates() -> AsyncStream<HLSFeedBackgroundWarmingSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshotValue())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func machineReadableSummary() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshotValue())
    }

    @discardableResult
    public func warm(
        _ request: HLSFeedBackgroundWarmingRequest
    ) async -> HLSFeedBackgroundWarmingResult {
        requestCount = Self.add(requestCount, 1)
        candidateItemCount = Self.add(candidateItemCount, request.candidates.count)
        guard !isRunning else {
            return finish(Self.emptyResult(.deniedBusy, request: request))
        }
        guard !Task.isCancelled else {
            return finish(Self.emptyResult(.cancelled, request: request))
        }
        if let denial = denial(for: request) {
            return finish(Self.emptyResult(denial, request: request))
        }

        let selection = select(from: request.candidates)
        skippedFreshCacheItemCount = Self.add(
            skippedFreshCacheItemCount,
            selection.freshSkipCount
        )
        skippedBudgetItemCount = Self.add(skippedBudgetItemCount, selection.budgetSkipCount)
        guard !selection.candidates.isEmpty else {
            return finish(HLSFeedBackgroundWarmingResult(
                outcome: .noEligibleWork,
                candidateItemCount: request.candidates.count,
                admittedItemCount: 0,
                preparedItemCount: 0,
                failedItemCount: 0,
                skippedFreshCacheItemCount: selection.freshSkipCount,
                skippedBudgetItemCount: selection.budgetSkipCount,
                admittedEstimatedByteCount: 0,
                preparedLeadingSegmentCount: 0,
                preparedResourceCount: 0,
                preparedByteCount: 0,
                cacheHitCount: 0,
                originFetchCount: 0,
                cacheHitByteCount: 0,
                originFetchByteCount: 0,
                maximumConcurrentPreparationCount: 0
            ))
        }

        isRunning = true
        defer { isRunning = false }
        admittedRequestCount = Self.add(admittedRequestCount, 1)
        admittedItemCount = Self.add(admittedItemCount, selection.candidates.count)
        nextGeneration &+= 1
        let generation = FeedNavigationGeneration(rawValue: nextGeneration)
        let duration = min(policy.maximumExecutionTime, request.availableExecutionTime)
        let outcome = await race(
            candidates: selection.candidates,
            generation: generation,
            duration: duration
        )

        let result: HLSFeedBackgroundWarmingResult
        switch outcome {
        case .expired(let batch):
            result = Self.result(
                outcome: .expired,
                request: request,
                selection: selection,
                batch: batch
            )
        case .cancelled(let batch):
            result = Self.result(
                outcome: .cancelled,
                request: request,
                selection: selection,
                batch: batch
            )
        case .batch(let batch):
            let terminal: HLSFeedBackgroundWarmingSnapshot.Outcome
            if Task.isCancelled || batch.cancelledItemCount > 0 {
                terminal = .cancelled
            } else if batch.failedItemCount == selection.candidates.count {
                terminal = .failed
            } else if batch.failedItemCount > 0 {
                terminal = .completedWithFailures
            } else {
                terminal = .completed
            }
            result = Self.result(
                outcome: terminal,
                request: request,
                selection: selection,
                batch: batch
            )
        }
        return finish(result)
    }

    private func denial(
        for request: HLSFeedBackgroundWarmingRequest
    ) -> HLSFeedBackgroundWarmingSnapshot.Outcome? {
        if request.availableExecutionTime <= .zero { return .expired }
        if request.environment.isLowPowerModeEnabled, !policy.allowsLowPowerMode {
            return .deniedLowPower
        }
        if request.environment.networkInterface == .unavailable { return .deniedOffline }
        if request.environment.networkInterface == .cellular, !policy.allowsCellularAccess {
            return .deniedCellular
        }
        if request.environment.isConstrained, !policy.allowsConstrainedNetworkAccess {
            return .deniedConstrained
        }
        if request.environment.isExpensive, !policy.allowsExpensiveNetworkAccess {
            return .deniedExpensive
        }
        return nil
    }

    private func select(
        from candidates: [HLSFeedBackgroundWarmingCandidate]
    ) -> Selection {
        var selected: [HLSFeedBackgroundWarmingCandidate] = []
        var selectedIDs: Set<FeedItemID> = []
        var estimatedBytes = 0
        var freshSkips = 0
        var budgetSkips = 0
        for candidate in candidates {
            guard selectedIDs.insert(candidate.item.id).inserted else { continue }
            if case .fresh(let remaining) = candidate.cacheState,
               remaining >= policy.minimumRemainingCacheValidity {
                freshSkips += 1
                continue
            }
            guard selected.count < policy.maximumItemCount else {
                budgetSkips += 1
                continue
            }
            let addition = candidate.item.estimatedPreparationBytes
            let (nextBytes, overflow) = estimatedBytes.addingReportingOverflow(addition)
            guard !overflow, nextBytes <= policy.maximumEstimatedByteCount else {
                budgetSkips += 1
                continue
            }
            selected.append(candidate)
            estimatedBytes = nextBytes
        }
        return Selection(
            candidates: selected,
            freshSkipCount: freshSkips,
            budgetSkipCount: budgetSkips,
            estimatedByteCount: estimatedBytes
        )
    }

    private func race(
        candidates: [HLSFeedBackgroundWarmingCandidate],
        generation: FeedNavigationGeneration,
        duration: Duration
    ) async -> RaceOutcome {
        let backend = self.backend
        let clock = self.clock
        let policy = self.policy
        return await withTaskGroup(of: RaceOutcome.self, returning: RaceOutcome.self) { group in
            group.addTask {
                .batch(await Self.prepare(
                    candidates,
                    generation: generation,
                    policy: policy,
                    backend: backend
                ))
            }
            group.addTask {
                do {
                    try await clock.sleep(for: duration)
                    return .expired(Batch())
                } catch {
                    return .cancelled(Batch())
                }
            }
            let first = await group.next() ?? .cancelled(Batch())
            group.cancelAll()
            let second = await group.next()
            let partialBatch: Batch
            if case .batch(let batch) = first {
                partialBatch = batch
            } else if case .batch(let batch) = second {
                partialBatch = batch
            } else {
                partialBatch = Batch()
            }
            if Task.isCancelled { return .cancelled(partialBatch) }
            switch first {
            case .batch:
                return .batch(partialBatch)
            case .expired:
                return .expired(partialBatch)
            case .cancelled:
                return .cancelled(partialBatch)
            }
        }
    }

    private static func prepare(
        _ candidates: [HLSFeedBackgroundWarmingCandidate],
        generation: FeedNavigationGeneration,
        policy: HLSFeedBackgroundWarmingPolicy,
        backend: any FeedPreparing
    ) async -> Batch {
        await withTaskGroup(of: ItemOutcome.self, returning: Batch.self) { group in
            let limit = min(policy.maximumConcurrentPreparations, candidates.count)
            var nextIndex = 0
            var active = 0
            var batch = Batch()

            func submit(_ candidate: HLSFeedBackgroundWarmingCandidate) {
                group.addTask {
                    do {
                        let value = try await backend.prepare(FeedPreparationRequest(
                            item: candidate.item,
                            generation: generation,
                            role: .predicted,
                            maximumLeadingSegments: policy.maximumLeadingSegmentsPerItem,
                            maximumConcurrentFetches: 1
                        ))
                        return .prepared(value)
                    } catch is CancellationError {
                        return .cancelled
                    } catch let error as URLError where error.code == .cancelled {
                        return .cancelled
                    } catch {
                        return Task.isCancelled ? .cancelled : .failed
                    }
                }
            }

            while nextIndex < limit {
                submit(candidates[nextIndex])
                nextIndex += 1
                active += 1
            }
            batch.maximumConcurrency = active

            while let outcome = await group.next() {
                active -= 1
                switch outcome {
                case .prepared(let value): batch.add(value)
                case .failed: batch.failedItemCount += 1
                case .cancelled: batch.cancelledItemCount += 1
                }
                if nextIndex < candidates.count, !Task.isCancelled {
                    submit(candidates[nextIndex])
                    nextIndex += 1
                    active += 1
                    batch.maximumConcurrency = max(batch.maximumConcurrency, active)
                }
            }
            return batch
        }
    }

    private func finish(
        _ result: HLSFeedBackgroundWarmingResult
    ) -> HLSFeedBackgroundWarmingResult {
        outcomeCounts[result.outcome] = Self.add(outcomeCounts[result.outcome] ?? 0, 1)
        preparedItemCount = Self.add(preparedItemCount, result.preparedItemCount)
        failedItemCount = Self.add(failedItemCount, result.failedItemCount)
        preparedLeadingSegmentCount = Self.add(
            preparedLeadingSegmentCount,
            result.preparedLeadingSegmentCount
        )
        preparedResourceCount = Self.add(preparedResourceCount, result.preparedResourceCount)
        preparedByteCount = Self.add(preparedByteCount, result.preparedByteCount)
        cacheHitCount = Self.add(cacheHitCount, result.cacheHitCount)
        originFetchCount = Self.add(originFetchCount, result.originFetchCount)
        cacheHitByteCount = Self.add(cacheHitByteCount, result.cacheHitByteCount)
        originFetchByteCount = Self.add(originFetchByteCount, result.originFetchByteCount)
        maximumObservedConcurrentPreparations = max(
            maximumObservedConcurrentPreparations,
            result.maximumConcurrentPreparationCount
        )
        publishSnapshot()
        return result
    }

    private func snapshotValue() -> HLSFeedBackgroundWarmingSnapshot {
        HLSFeedBackgroundWarmingSnapshot(
            requestCount: requestCount,
            admittedRequestCount: admittedRequestCount,
            outcomes: HLSFeedBackgroundWarmingSnapshot.Outcome.allCases.map {
                .init(outcome: $0, count: outcomeCounts[$0] ?? 0)
            },
            candidateItemCount: candidateItemCount,
            admittedItemCount: admittedItemCount,
            preparedItemCount: preparedItemCount,
            failedItemCount: failedItemCount,
            skippedFreshCacheItemCount: skippedFreshCacheItemCount,
            skippedBudgetItemCount: skippedBudgetItemCount,
            preparedLeadingSegmentCount: preparedLeadingSegmentCount,
            preparedResourceCount: preparedResourceCount,
            preparedByteCount: preparedByteCount,
            cacheHitCount: cacheHitCount,
            originFetchCount: originFetchCount,
            cacheHitByteCount: cacheHitByteCount,
            originFetchByteCount: originFetchByteCount,
            maximumObservedConcurrentPreparations: maximumObservedConcurrentPreparations,
            maximumOutcomeCardinality: HLSFeedBackgroundWarmingSnapshot.Outcome.allCases.count
        )
    }

    private func publishSnapshot() {
        let value = snapshotValue()
        for continuation in continuations.values { continuation.yield(value) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func emptyResult(
        _ outcome: HLSFeedBackgroundWarmingSnapshot.Outcome,
        request: HLSFeedBackgroundWarmingRequest,
        selection: Selection? = nil
    ) -> HLSFeedBackgroundWarmingResult {
        HLSFeedBackgroundWarmingResult(
            outcome: outcome,
            candidateItemCount: request.candidates.count,
            admittedItemCount: selection?.candidates.count ?? 0,
            preparedItemCount: 0,
            failedItemCount: 0,
            skippedFreshCacheItemCount: selection?.freshSkipCount ?? 0,
            skippedBudgetItemCount: selection?.budgetSkipCount ?? 0,
            admittedEstimatedByteCount: selection?.estimatedByteCount ?? 0,
            preparedLeadingSegmentCount: 0,
            preparedResourceCount: 0,
            preparedByteCount: 0,
            cacheHitCount: 0,
            originFetchCount: 0,
            cacheHitByteCount: 0,
            originFetchByteCount: 0,
            maximumConcurrentPreparationCount: 0
        )
    }

    private static func result(
        outcome: HLSFeedBackgroundWarmingSnapshot.Outcome,
        request: HLSFeedBackgroundWarmingRequest,
        selection: Selection,
        batch: Batch
    ) -> HLSFeedBackgroundWarmingResult {
        HLSFeedBackgroundWarmingResult(
            outcome: outcome,
            candidateItemCount: request.candidates.count,
            admittedItemCount: selection.candidates.count,
            preparedItemCount: batch.preparedItemCount,
            failedItemCount: batch.failedItemCount,
            skippedFreshCacheItemCount: selection.freshSkipCount,
            skippedBudgetItemCount: selection.budgetSkipCount,
            admittedEstimatedByteCount: selection.estimatedByteCount,
            preparedLeadingSegmentCount: batch.leadingSegmentCount,
            preparedResourceCount: batch.resourceCount,
            preparedByteCount: batch.byteCount,
            cacheHitCount: batch.cacheHitCount,
            originFetchCount: batch.originFetchCount,
            cacheHitByteCount: batch.cacheHitByteCount,
            originFetchByteCount: batch.originFetchByteCount,
            maximumConcurrentPreparationCount: batch.maximumConcurrency
        )
    }

    private static func backendPolicy(
        from feedPolicy: FeedPlaybackPolicy,
        warmingPolicy: HLSFeedBackgroundWarmingPolicy
    ) throws -> FeedPlaybackPolicy {
        var value = try feedPolicy.validated()
        value.prefetch.aheadItemCount = 0
        value.prefetch.behindItemCount = 0
        value.prefetch.maximumLeadingSegments = warmingPolicy.maximumLeadingSegmentsPerItem
        value.budget.maximumResidentItems = 1
        value.budget.maximumEstimatedPreparationBytes = warmingPolicy.maximumEstimatedByteCount
        value.concurrency.maximumConcurrentPreparations = warmingPolicy.maximumConcurrentPreparations
        value.concurrency.maximumConcurrentFetches = 1
        value.concurrency.maximumPlayerCount = 1
        value.network = HLSOriginNetworkPolicy(
            requestTimeout: value.network.requestTimeout,
            resourceTimeout: value.network.resourceTimeout,
            waitsForConnectivity: false,
            allowsConstrainedNetworkAccess: warmingPolicy.allowsConstrainedNetworkAccess,
            allowsExpensiveNetworkAccess: warmingPolicy.allowsExpensiveNetworkAccess,
            maximumConnectionsPerHost: 1
        )
        value.looping = .disabled
        value.lowPower = .init(
            maximumPrefetchItems: 0,
            maximumLeadingSegments: warmingPolicy.maximumLeadingSegmentsPerItem,
            maximumConcurrentPreparations: 1,
            maximumConcurrentFetches: 1,
            maximumPlayerCount: 1
        )
        return try value.validated()
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func add(_ lhs: UInt64, _ rhs: Int) -> UInt64 {
        guard rhs > 0 else { return lhs }
        return add(lhs, UInt64(rhs))
    }
}
