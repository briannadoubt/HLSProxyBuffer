import Foundation
import HLSCore

/// Injectable monotonic time for cancellation accounting and deterministic tests.
public struct FeedCoordinatorClock: Sendable {
    public static let continuous: Self = {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: { origin.duration(to: clock.now) })
    }()

    private let nowProvider: @Sendable () -> Duration

    public init(now: @escaping @Sendable () -> Duration) {
        self.nowProvider = now
    }

    func now() -> Duration {
        max(.zero, nowProvider())
    }
}

public enum FeedCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case stopped

    public var errorDescription: String? {
        switch self {
        case .stopped: "The feed coordinator has been stopped"
        }
    }
}

/// One immutable view of bounded preparation work and reusable readiness.
public struct FeedCoordinatorSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            case queued
            case preparing
            case ready(FeedPreparedItem)
            case failed(String)
        }

        public let itemID: FeedItemID
        public let role: FeedPlan.Role
        public let estimatedPreparationBytes: Int
        public let status: Status
    }

    public let generation: FeedNavigationGeneration?
    public let entries: [Entry]
    public let activePreparationCount: Int
    public let queuedPreparationCount: Int
    public let residentEstimatedPreparationBytes: Int
    public let maximumObservedActivePreparations: Int
    public let preparationCacheReuseCount: Int
    public let cancellationRequestCount: Int
    public let cancellationAcknowledgementCount: Int
    public let lateCancellationCount: Int
    public let maximumCancellationLatency: Duration?
    public let discardedStaleResultCount: Int

    public var isIdle: Bool {
        activePreparationCount == 0 && queuedPreparationCount == 0
    }

    public var readyItemIDs: Set<FeedItemID> {
        Set(entries.compactMap { entry in
            if case .ready = entry.status { return entry.itemID }
            return nil
        })
    }
}

/// Actor-isolated predictive preparation for UI-independent feed signals.
///
/// The coordinator admits only the pure planner's bounded working set, starts
/// no more than the policy's preparation concurrency, and invalidates every
/// older-generation task before accepting a new navigation generation.
/// Successful work is published only when its generation and policy revision
/// are still current.
public actor FeedCoordinator {
    private struct Work {
        let token: UUID
        let itemID: FeedItemID
        let generation: FeedNavigationGeneration
        let policyRevision: UInt64
        let cancellationDeadline: Duration
        var cancellationRequestedAt: Duration?
        let task: Task<Void, Never>
    }

    private struct Failure {
        let generation: FeedNavigationGeneration
        let policyRevision: UInt64
        let message: String
    }

    private struct CachedPreparation {
        let item: FeedPlaybackItem
        let value: FeedPreparedItem
        var access: UInt64
    }

    private enum WorkOutcome: Sendable {
        case success(FeedPreparedItem)
        case failure(String)
        case cancelled
    }

    private var items: [FeedPlaybackItem]
    private var itemsByID: [FeedItemID: FeedPlaybackItem]
    private var basePolicy: FeedPlaybackPolicy
    private var effectivePolicy: FeedPlaybackPolicy
    private var planner: FeedPlanner
    private let backend: any FeedPreparing
    private let clock: FeedCoordinatorClock
    private var qualityPolicy: HLSRewriteConfiguration.QualityPolicy
    private var isLowPowerModeEnabled = false
    private var lastSignal: FeedViewportSignal?
    private var currentPlan: FeedPlan?
    private var desiredEntries: [FeedPlan.Entry] = []
    private var resident: [FeedItemID: FeedPreparedItem] = [:]
    private var works: [UUID: Work] = [:]
    private var failures: [FeedItemID: Failure] = [:]
    private var preparationCache: [FeedItemID: CachedPreparation] = [:]
    private var cacheAccessCounter: UInt64 = 0
    private var policyRevision: UInt64 = 0
    private var isStopped = false
    private var continuations: [UUID: AsyncStream<FeedCoordinatorSnapshot>.Continuation] = [:]

    private var maximumObservedActivePreparations = 0
    private var preparationCacheReuseCount = 0
    private var cancellationRequestCount = 0
    private var cancellationAcknowledgementCount = 0
    private var lateCancellationCount = 0
    private var maximumCancellationLatency: Duration?
    private var discardedStaleResultCount = 0

    public init(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        backend: any FeedPreparing,
        clock: FeedCoordinatorClock = .continuous
    ) throws {
        let validatedPolicy = try policy.validated()
        let limits = try validatedPolicy.makePlanningLimits()
        let configuration = try validatedPolicy.makeProxyPlayerConfiguration()
        self.items = items
        self.itemsByID = try Self.validatedItemsByID(items)
        self.basePolicy = validatedPolicy
        self.effectivePolicy = validatedPolicy
        self.planner = FeedPlanner(limits: limits)
        self.backend = backend
        self.clock = clock
        self.qualityPolicy = configuration.qualityPolicy
    }

    public init(
        items: [FeedPlaybackItem],
        policy: FeedPlaybackPolicy,
        clock: FeedCoordinatorClock = .continuous
    ) throws {
        let backend = try HLSFeedPreparationBackend(policy: policy)
        try self.init(items: items, policy: policy, backend: backend, clock: clock)
    }

    /// Applies one visibility/prediction observation and starts bounded work.
    @discardableResult
    public func submit(_ signal: FeedViewportSignal) throws -> FeedCoordinatorSnapshot {
        guard !isStopped else { throw FeedCoordinatorError.stopped }
        let previousGeneration = currentPlan?.generation
        let plan = try planner.makePlan(
            items: items,
            signal: signal,
            previousPlan: currentPlan
        )
        guard plan.disposition == .accepted else {
            return snapshotValue()
        }

        let generationAdvanced = previousGeneration.map { signal.generation > $0 } ?? true
        if generationAdvanced {
            cancelWorks { $0.generation < signal.generation }
            failures.removeAll(keepingCapacity: true)
            resident.removeAll(keepingCapacity: true)
        } else {
            // A fresh accepted observation is an explicit retry opportunity.
            failures.removeAll(keepingCapacity: true)
        }

        lastSignal = signal
        currentPlan = plan
        desiredEntries = plan.desiredEntries
        cancelUndesiredWorks()
        reconcileReadinessAndWork()
        publishSnapshot()
        return snapshotValue()
    }

    /// Replaces feed contents while preserving reusable results for unchanged items.
    @discardableResult
    public func replaceItems(
        _ items: [FeedPlaybackItem]
    ) throws -> FeedCoordinatorSnapshot {
        guard !isStopped else { throw FeedCoordinatorError.stopped }
        if let lastSignal {
            _ = try planner.makePlan(items: items, signal: lastSignal)
        } else {
            _ = try Self.validatedItemsByID(items)
        }

        let replacementByID = try Self.validatedItemsByID(items)
        let invalidatedIDs = Set(itemsByID.compactMap { itemID, oldItem in
            replacementByID[itemID] == oldItem ? nil : itemID
        })
        cancelWorks { invalidatedIDs.contains($0.itemID) || replacementByID[$0.itemID] == nil }
        for itemID in invalidatedIDs {
            resident.removeValue(forKey: itemID)
            preparationCache.removeValue(forKey: itemID)
            failures.removeValue(forKey: itemID)
        }
        resident = resident.filter { replacementByID[$0.key] != nil }
        preparationCache = preparationCache.filter { replacementByID[$0.key] != nil }
        failures = failures.filter { replacementByID[$0.key] != nil }
        self.items = items
        self.itemsByID = replacementByID
        currentPlan = nil
        desiredEntries = []
        if let lastSignal {
            let plan = try planner.makePlan(items: items, signal: lastSignal)
            currentPlan = plan
            desiredEntries = plan.desiredEntries
        }
        cancelUndesiredWorks()
        reconcileReadinessAndWork()
        publishSnapshot()
        return snapshotValue()
    }

    /// Revalidates all bounds and invalidates work admitted by the old policy.
    @discardableResult
    public func updatePolicy(
        _ policy: FeedPlaybackPolicy
    ) async throws -> FeedCoordinatorSnapshot {
        guard !isStopped else { throw FeedCoordinatorError.stopped }
        basePolicy = try policy.validated()
        return try await applyEffectivePolicy()
    }

    /// Applies the policy's low-power caps without disrupting reusable readiness.
    @discardableResult
    public func setLowPowerModeEnabled(
        _ isEnabled: Bool
    ) async throws -> FeedCoordinatorSnapshot {
        guard !isStopped else { throw FeedCoordinatorError.stopped }
        guard isLowPowerModeEnabled != isEnabled else { return snapshotValue() }
        isLowPowerModeEnabled = isEnabled
        return try await applyEffectivePolicy()
    }

    /// Latest state without waiting for in-flight work.
    public func snapshot() -> FeedCoordinatorSnapshot {
        snapshotValue()
    }

    /// Bounded, newest-only state suitable for Observation adapters and tests.
    public func updates() -> AsyncStream<FeedCoordinatorSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(snapshotValue())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Waits for the currently admitted work and any resulting bounded batch.
    public func waitUntilIdle() async -> FeedCoordinatorSnapshot {
        while !works.isEmpty {
            let tasks = works.values.map(\.task)
            for task in tasks {
                await task.value
            }
        }
        return snapshotValue()
    }

    /// Cancels all work and permanently closes state streams.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        cancelWorks { _ in true }
        let tasks = works.values.map(\.task)
        for task in tasks {
            await task.value
        }
        desiredEntries = []
        currentPlan = nil
        resident.removeAll(keepingCapacity: false)
        let finalSnapshot = snapshotValue()
        for continuation in continuations.values {
            continuation.yield(finalSnapshot)
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// Drops coordinator-level readiness reuse. The backend cache remains policy-owned.
    public func clearPreparationReuse() {
        preparationCache.removeAll(keepingCapacity: false)
        cacheAccessCounter = 0
    }

    private func applyEffectivePolicy() async throws -> FeedCoordinatorSnapshot {
        let adapted = try basePolicy.adaptedForLowPowerMode(isLowPowerModeEnabled)
        let configuration = try adapted.makeProxyPlayerConfiguration()
        policyRevision &+= 1
        cancelWorks { _ in true }
        failures.removeAll(keepingCapacity: true)
        currentPlan = nil
        desiredEntries = []
        try await backend.update(policy: adapted)
        effectivePolicy = adapted
        planner = FeedPlanner(limits: try adapted.makePlanningLimits())
        qualityPolicy = configuration.qualityPolicy
        if let lastSignal {
            let plan = try planner.makePlan(items: items, signal: lastSignal)
            currentPlan = plan
            desiredEntries = plan.desiredEntries
        }
        cancelUndesiredWorks()
        reconcileReadinessAndWork()
        publishSnapshot()
        return snapshotValue()
    }

    private func reconcileReadinessAndWork() {
        guard !isStopped else { return }
        let desiredIDs = Set(desiredEntries.map(\.itemID))
        resident = resident.filter { desiredIDs.contains($0.key) }

        var shouldTryExpansion = true
        while shouldTryExpansion {
            shouldTryExpansion = false
            for entry in desiredEntries where resident[entry.itemID] == nil {
                guard let item = itemsByID[entry.itemID],
                      var cached = preparationCache[entry.itemID],
                      cached.item == item,
                      cached.value.leadingSegmentCount >= leadingSegmentLimit(for: entry.role)
                else {
                    continue
                }
                cacheAccessCounter &+= 1
                cached.access = cacheAccessCounter
                preparationCache[entry.itemID] = cached
                resident[entry.itemID] = cached.value.rebased(
                    to: currentPlan?.generation ?? cached.value.generation
                )
                preparationCacheReuseCount += 1
                shouldTryExpansion = true
            }

            if allCurrentEntriesAreSettled(), expandCurrentPlan() {
                shouldTryExpansion = true
            }
        }

        cancelUndesiredWorks()
        startPendingWork()
    }

    private func allCurrentEntriesAreSettled() -> Bool {
        desiredEntries.allSatisfy { entry in
            if resident[entry.itemID] != nil { return true }
            if let failure = failures[entry.itemID] {
                return failure.generation == currentPlan?.generation
                    && failure.policyRevision == policyRevision
            }
            return false
        }
    }

    private func expandCurrentPlan() -> Bool {
        guard let lastSignal, let currentPlan else { return false }
        guard let expanded = try? planner.makePlan(
            items: items,
            signal: lastSignal,
            previousPlan: currentPlan
        ) else {
            return false
        }
        guard expanded.desiredEntries != desiredEntries else { return false }
        self.currentPlan = expanded
        desiredEntries = expanded.desiredEntries
        return true
    }

    private func startPendingWork() {
        guard !isStopped else { return }
        let limit = effectivePolicy.concurrency.maximumConcurrentPreparations
        guard works.count < limit, let generation = currentPlan?.generation else { return }
        let activeItemIDs = Set(works.values.map(\.itemID))
        let slots = limit - works.count
        let candidates = desiredEntries.filter { entry in
            resident[entry.itemID] == nil
                && !activeItemIDs.contains(entry.itemID)
                && !hasCurrentFailure(for: entry.itemID, generation: generation)
        }
        for entry in candidates.prefix(slots) {
            startWork(for: entry, generation: generation)
        }
    }

    private func startWork(
        for entry: FeedPlan.Entry,
        generation: FeedNavigationGeneration
    ) {
        guard let item = itemsByID[entry.itemID] else { return }
        let token = UUID()
        let revision = policyRevision
        let backend = self.backend
        let request = FeedPreparationRequest(
            item: item,
            generation: generation,
            role: entry.role,
            maximumLeadingSegments: leadingSegmentLimit(for: entry.role),
            maximumConcurrentFetches: effectivePolicy.concurrency.maximumConcurrentFetches,
            qualityPolicy: qualityPolicy
        )
        let task = Task { [weak self] in
            let outcome: WorkOutcome
            do {
                let value = try await backend.prepare(request)
                // A backend may return after cancellation. Preserve that fact so
                // generation validation can count and discard the stale result.
                outcome = .success(value)
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as URLError where error.code == .cancelled {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failure(error.localizedDescription)
            }
            await self?.finishWork(token: token, outcome: outcome)
        }
        works[token] = Work(
            token: token,
            itemID: entry.itemID,
            generation: generation,
            policyRevision: revision,
            cancellationDeadline: planner.limits.cancellationDeadline,
            cancellationRequestedAt: nil,
            task: task
        )
        maximumObservedActivePreparations = max(maximumObservedActivePreparations, works.count)
    }

    private func finishWork(token: UUID, outcome: WorkOutcome) {
        guard let work = works.removeValue(forKey: token) else { return }
        if let requestedAt = work.cancellationRequestedAt {
            let latency = max(Duration.zero, clock.now() - requestedAt)
            cancellationAcknowledgementCount += 1
            maximumCancellationLatency = maxDuration(maximumCancellationLatency, latency)
            if latency > work.cancellationDeadline {
                lateCancellationCount += 1
            }
        }

        let isCurrent = work.generation == currentPlan?.generation
            && work.policyRevision == policyRevision
            && desiredEntries.contains { $0.itemID == work.itemID }
            && work.cancellationRequestedAt == nil
            && !isStopped
        if isCurrent {
            switch outcome {
            case .success(let value):
                resident[work.itemID] = value
                insertIntoPreparationCache(value, itemID: work.itemID)
                failures.removeValue(forKey: work.itemID)
            case .failure(let message):
                failures[work.itemID] = Failure(
                    generation: work.generation,
                    policyRevision: work.policyRevision,
                    message: message
                )
            case .cancelled:
                break
            }
        } else if case .success = outcome {
            discardedStaleResultCount += 1
        }

        reconcileReadinessAndWork()
        publishSnapshot()
    }

    private func insertIntoPreparationCache(
        _ value: FeedPreparedItem,
        itemID: FeedItemID
    ) {
        guard let item = itemsByID[itemID] else { return }
        cacheAccessCounter &+= 1
        preparationCache[itemID] = CachedPreparation(
            item: item,
            value: value,
            access: cacheAccessCounter
        )
        let maximumCount = effectivePolicy.budget.maximumCacheEntryCount
        while preparationCache.count > maximumCount,
              let oldest = preparationCache.min(by: { $0.value.access < $1.value.access })?.key {
            preparationCache.removeValue(forKey: oldest)
        }
    }

    private func cancelUndesiredWorks() {
        let desiredIDs = Set(desiredEntries.map(\.itemID))
        cancelWorks { work in
            work.generation != currentPlan?.generation
                || work.policyRevision != policyRevision
                || !desiredIDs.contains(work.itemID)
        }
    }

    private func cancelWorks(where shouldCancel: (Work) -> Bool) {
        let now = clock.now()
        for token in Array(works.keys) {
            guard var work = works[token],
                  work.cancellationRequestedAt == nil,
                  shouldCancel(work)
            else {
                continue
            }
            work.cancellationRequestedAt = now
            works[token] = work
            cancellationRequestCount += 1
            work.task.cancel()
        }
    }

    private func hasCurrentFailure(
        for itemID: FeedItemID,
        generation: FeedNavigationGeneration
    ) -> Bool {
        guard let failure = failures[itemID] else { return false }
        return failure.generation == generation && failure.policyRevision == policyRevision
    }

    private func leadingSegmentLimit(for role: FeedPlan.Role) -> Int {
        let maximum = effectivePolicy.prefetch.maximumLeadingSegments
        guard role != .focused else { return maximum }
        let focusedSeconds = effectivePolicy.prefetch.focusedBufferSeconds
        let warmSeconds = effectivePolicy.prefetch.warmBufferSeconds
        guard focusedSeconds > 0, warmSeconds > 0 else { return 1 }
        let ratio = min(1, warmSeconds / focusedSeconds)
        return max(1, min(maximum, Int(ceil(Double(maximum) * ratio))))
    }

    private func snapshotValue() -> FeedCoordinatorSnapshot {
        let generation = currentPlan?.generation
        let entries = desiredEntries.map { entry in
            let status: FeedCoordinatorSnapshot.Entry.Status
            if let value = resident[entry.itemID] {
                status = .ready(value)
            } else if works.values.contains(where: {
                $0.itemID == entry.itemID
                    && $0.generation == generation
                    && $0.policyRevision == policyRevision
                    && $0.cancellationRequestedAt == nil
            }) {
                status = .preparing
            } else if let failure = failures[entry.itemID],
                      failure.generation == generation,
                      failure.policyRevision == policyRevision {
                status = .failed(failure.message)
            } else {
                status = .queued
            }
            return FeedCoordinatorSnapshot.Entry(
                itemID: entry.itemID,
                role: entry.role,
                estimatedPreparationBytes: entry.estimatedPreparationBytes,
                status: status
            )
        }
        let queued = entries.reduce(into: 0) { count, entry in
            if case .queued = entry.status { count += 1 }
        }
        return FeedCoordinatorSnapshot(
            generation: generation,
            entries: entries,
            activePreparationCount: works.count,
            queuedPreparationCount: queued,
            residentEstimatedPreparationBytes: desiredEntries
                .filter { resident[$0.itemID] != nil }
                .reduce(0) { $0 + $1.estimatedPreparationBytes },
            maximumObservedActivePreparations: maximumObservedActivePreparations,
            preparationCacheReuseCount: preparationCacheReuseCount,
            cancellationRequestCount: cancellationRequestCount,
            cancellationAcknowledgementCount: cancellationAcknowledgementCount,
            lateCancellationCount: lateCancellationCount,
            maximumCancellationLatency: maximumCancellationLatency,
            discardedStaleResultCount: discardedStaleResultCount
        )
    }

    private func publishSnapshot() {
        let value = snapshotValue()
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func maxDuration(_ current: Duration?, _ candidate: Duration) -> Duration {
        guard let current else { return candidate }
        return max(current, candidate)
    }

    private static func validatedItemsByID(
        _ items: [FeedPlaybackItem]
    ) throws -> [FeedItemID: FeedPlaybackItem] {
        var result: [FeedItemID: FeedPlaybackItem] = [:]
        result.reserveCapacity(items.count)
        for item in items {
            guard !item.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeedPlanningError.emptyItemID
            }
            guard result[item.id] == nil else {
                throw FeedPlanningError.duplicateItemID(item.id)
            }
            if item.source.hasEmptyClipSequence {
                throw FeedPlanningError.emptyClipSequence(item.id)
            }
            result[item.id] = item
        }
        return result
    }
}

private extension FeedPreparedItem {
    func rebased(to generation: FeedNavigationGeneration) -> Self {
        Self(
            itemID: itemID,
            generation: generation,
            manifestURLs: manifestURLs,
            mediaPlaylistCount: mediaPlaylistCount,
            leadingSegmentCount: leadingSegmentCount,
            preparedResourceCount: preparedResourceCount,
            preparedByteCount: preparedByteCount,
            cacheHitCount: cacheHitCount,
            originFetchCount: originFetchCount
        )
    }
}
