import Foundation

/// Typed failures that prevent a coherent, bounded feed plan.
public enum FeedPlanningError: Error, Equatable, LocalizedError, Sendable {
    case emptyItemID
    case duplicateItemID(FeedItemID)
    case emptyClipSequence(FeedItemID)
    case unknownFocusedItem(FeedItemID)
    case unknownVisibleItem(FeedItemID)
    case unknownPredictedItem(FeedItemID)
    case focusedItemExceedsByteBudget(itemID: FeedItemID, required: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyItemID:
            "Feed item IDs must not be empty"
        case .duplicateItemID(let itemID):
            "Feed item ID is not unique: \(itemID)"
        case .emptyClipSequence(let itemID):
            "Clip sequence is empty for feed item: \(itemID)"
        case .unknownFocusedItem(let itemID):
            "Focused feed item is not in the ordered item collection: \(itemID)"
        case .unknownVisibleItem(let itemID):
            "Visible feed item is not in the ordered item collection: \(itemID)"
        case .unknownPredictedItem(let itemID):
            "Predicted feed item is not in the ordered item collection: \(itemID)"
        case .focusedItemExceedsByteBudget(let itemID, let required, let limit):
            "Focused feed item \(itemID) requires \(required) estimated bytes; limit is \(limit)"
        }
    }
}

/// A fast, deterministic model for desired feed residency and cancellation.
///
/// The planner performs no I/O and creates no tasks. The feed coordinator uses
/// its ordered output to admit structured-concurrency work while preserving the
/// same generation, byte, item, and concurrency bounds.
public struct FeedPlanner: Sendable {
    public var limits: FeedPlanningLimits

    public init(limits: FeedPlanningLimits = .init()) {
        self.limits = limits
    }

    /// Produces a bounded transition for the latest viewport signal.
    ///
    /// A signal older than `previousPlan` is ignored and schedules no work.
    /// Same-generation signals may refine visibility and prediction without
    /// invalidating results that belong to that navigation epoch.
    public func makePlan(
        items: [FeedPlaybackItem],
        signal: FeedViewportSignal,
        previousPlan: FeedPlan? = nil
    ) throws -> FeedPlan {
        if let previousPlan, signal.generation < previousPlan.generation {
            return FeedPlan(
                generation: previousPlan.generation,
                disposition: .ignoredStaleSignal,
                desiredEntries: previousPlan.desiredEntries,
                preparations: [],
                cancellations: []
            )
        }

        let indexedItems = try validatedItems(items)
        try validate(signal: signal, against: indexedItems.byID)

        let candidates = rankedCandidates(
            items: items,
            itemIndices: indexedItems.indices,
            signal: signal
        )
        let targetEntries = try admitCandidates(candidates, itemsByID: indexedItems.byID, signal: signal)
        let previousEntries = previousPlan?.desiredEntries ?? []
        let previousIDs = Set(previousEntries.map(\.itemID))
        let targetIDs = Set(targetEntries.map(\.itemID))

        let retainedEntries = targetEntries.filter { previousIDs.contains($0.itemID) }
        let preparationSlots = max(0, limits.maximumConcurrentPreparations)
        let preparations = targetEntries
            .filter { !previousIDs.contains($0.itemID) }
            .prefix(preparationSlots)
        let admittedIDs = Set(retainedEntries.map(\.itemID)).union(preparations.map(\.itemID))
        let desiredEntries = targetEntries.filter { admittedIDs.contains($0.itemID) }

        let cancellationDeadline = signal.observedAt + limits.cancellationDeadline
        let cancellations = previousEntries.compactMap { entry -> FeedPlan.Cancellation? in
            guard !targetIDs.contains(entry.itemID) else { return nil }
            return .init(
                itemID: entry.itemID,
                requestedAt: signal.observedAt,
                deadline: cancellationDeadline
            )
        }

        return FeedPlan(
            generation: signal.generation,
            disposition: .accepted,
            desiredEntries: desiredEntries,
            preparations: Array(preparations),
            cancellations: cancellations
        )
    }
}

private extension FeedPlanner {
    struct IndexedItems {
        let byID: [FeedItemID: FeedPlaybackItem]
        let indices: [FeedItemID: Int]
    }

    struct Candidate {
        let itemID: FeedItemID
        let role: FeedPlan.Role
    }

    func validatedItems(_ items: [FeedPlaybackItem]) throws -> IndexedItems {
        var byID: [FeedItemID: FeedPlaybackItem] = [:]
        var indices: [FeedItemID: Int] = [:]
        byID.reserveCapacity(items.count)
        indices.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            guard !item.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeedPlanningError.emptyItemID
            }
            guard byID[item.id] == nil else {
                throw FeedPlanningError.duplicateItemID(item.id)
            }
            if item.source.hasEmptyClipSequence {
                throw FeedPlanningError.emptyClipSequence(item.id)
            }
            byID[item.id] = item
            indices[item.id] = index
        }
        return IndexedItems(byID: byID, indices: indices)
    }

    func validate(
        signal: FeedViewportSignal,
        against itemsByID: [FeedItemID: FeedPlaybackItem]
    ) throws {
        if let focusedItemID = signal.focusedItemID, itemsByID[focusedItemID] == nil {
            throw FeedPlanningError.unknownFocusedItem(focusedItemID)
        }
        for visibility in signal.visibleItems where itemsByID[visibility.itemID] == nil {
            throw FeedPlanningError.unknownVisibleItem(visibility.itemID)
        }
        for prediction in signal.predictedDestinations where itemsByID[prediction.itemID] == nil {
            throw FeedPlanningError.unknownPredictedItem(prediction.itemID)
        }
    }

    func rankedCandidates(
        items: [FeedPlaybackItem],
        itemIndices: [FeedItemID: Int],
        signal: FeedViewportSignal
    ) -> [Candidate] {
        var result: [Candidate] = []
        var seen: Set<FeedItemID> = []
        let priorities = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.priority) })

        func append(_ itemID: FeedItemID, role: FeedPlan.Role) {
            guard seen.insert(itemID).inserted else { return }
            result.append(.init(itemID: itemID, role: role))
        }

        if let focusedItemID = signal.focusedItemID {
            append(focusedItemID, role: .focused)
        }

        let visible = signal.visibleItems.sorted { lhs, rhs in
            if lhs.fraction != rhs.fraction { return lhs.fraction > rhs.fraction }
            if abs(lhs.distanceInViewports) != abs(rhs.distanceInViewports) {
                return abs(lhs.distanceInViewports) < abs(rhs.distanceInViewports)
            }
            if priorities[lhs.itemID] != priorities[rhs.itemID] {
                return (priorities[lhs.itemID] ?? 0) > (priorities[rhs.itemID] ?? 0)
            }
            return (itemIndices[lhs.itemID] ?? .max) < (itemIndices[rhs.itemID] ?? .max)
        }
        visible.forEach { append($0.itemID, role: .visible) }

        let predictions = signal.predictedDestinations.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if priorities[lhs.itemID] != priorities[rhs.itemID] {
                return (priorities[lhs.itemID] ?? 0) > (priorities[rhs.itemID] ?? 0)
            }
            return (itemIndices[lhs.itemID] ?? .max) < (itemIndices[rhs.itemID] ?? .max)
        }
        predictions.forEach { append($0.itemID, role: .predicted) }

        guard limits.neighborPredictionHorizon > 0,
              !items.isEmpty,
              let anchorID = signal.focusedItemID ?? visible.first?.itemID,
              let anchorIndex = itemIndices[anchorID]
        else {
            return result
        }

        let direction = signal.velocityInViewportsPerSecond < 0 ? -1 : 1
        for distance in 1...limits.neighborPredictionHorizon {
            let preferredIndex = anchorIndex + (direction * distance)
            if items.indices.contains(preferredIndex) {
                append(items[preferredIndex].id, role: .neighbor)
            }
            if signal.velocityInViewportsPerSecond == 0 {
                let oppositeIndex = anchorIndex - (direction * distance)
                if items.indices.contains(oppositeIndex) {
                    append(items[oppositeIndex].id, role: .neighbor)
                }
            }
        }
        return result
    }

    func admitCandidates(
        _ candidates: [Candidate],
        itemsByID: [FeedItemID: FeedPlaybackItem],
        signal: FeedViewportSignal
    ) throws -> [FeedPlan.Entry] {
        let focusedAllowance = signal.focusedItemID == nil ? 0 : 1
        let maximumCount = min(
            limits.maximumResidentItems,
            focusedAllowance + limits.maximumPrefetchItems
        )
        guard maximumCount > 0 else { return [] }

        var entries: [FeedPlan.Entry] = []
        var estimatedBytes = 0
        entries.reserveCapacity(maximumCount)

        for candidate in candidates {
            guard entries.count < maximumCount,
                  let item = itemsByID[candidate.itemID]
            else { break }

            let (nextBytes, overflow) = estimatedBytes.addingReportingOverflow(
                item.estimatedPreparationBytes
            )
            let exceedsBudget = overflow || nextBytes > limits.maximumEstimatedPreparationBytes
            if exceedsBudget {
                if candidate.role == .focused {
                    throw FeedPlanningError.focusedItemExceedsByteBudget(
                        itemID: candidate.itemID,
                        required: item.estimatedPreparationBytes,
                        limit: limits.maximumEstimatedPreparationBytes
                    )
                }
                continue
            }

            entries.append(.init(
                itemID: candidate.itemID,
                role: candidate.role,
                estimatedPreparationBytes: item.estimatedPreparationBytes
            ))
            estimatedBytes = nextBytes
        }
        return entries
    }
}
