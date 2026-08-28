import Foundation

/// Hard limits applied by the pure feed planner.
///
/// HLS-14 composes these primitives into workload presets and focused
/// overrides. Values are normalized to safe nonnegative bounds at creation.
public struct FeedPlanningLimits: Hashable, Sendable {
    public let maximumResidentItems: Int
    public let maximumPrefetchItems: Int

    /// Hard ordered-collection bounds relative to the current anchor.
    /// Predictions and visible items outside this window are never admitted.
    public let maximumAheadItems: Int
    public let maximumBehindItems: Int
    public let maximumConcurrentPreparations: Int
    public let maximumEstimatedPreparationBytes: Int

    /// Compatibility fallback used for both directional bounds when callers
    /// do not provide `maximumAheadItems` and `maximumBehindItems`.
    public let neighborPredictionHorizon: Int

    /// Speeds below the directional threshold use symmetric nearest-first
    /// priority. Speeds at or above the fast threshold exhaust the direction
    /// of travel before ranking the opposite side.
    public let directionalVelocityThreshold: Double
    public let fastVelocityThreshold: Double
    public let cancellationDeadline: Duration

    public init(
        maximumResidentItems: Int = 3,
        maximumPrefetchItems: Int = 2,
        maximumConcurrentPreparations: Int = 2,
        maximumEstimatedPreparationBytes: Int = 64 * 1_024 * 1_024,
        neighborPredictionHorizon: Int = 2,
        maximumAheadItems: Int? = nil,
        maximumBehindItems: Int? = nil,
        directionalVelocityThreshold: Double = 0.25,
        fastVelocityThreshold: Double = 2,
        cancellationDeadline: Duration = .milliseconds(100)
    ) {
        let normalizedHorizon = max(0, neighborPredictionHorizon)
        let normalizedDirectionalThreshold = directionalVelocityThreshold.isFinite
            ? max(0, directionalVelocityThreshold)
            : 0
        self.maximumResidentItems = max(1, maximumResidentItems)
        self.maximumPrefetchItems = max(0, maximumPrefetchItems)
        self.maximumAheadItems = max(0, maximumAheadItems ?? normalizedHorizon)
        self.maximumBehindItems = max(0, maximumBehindItems ?? normalizedHorizon)
        self.maximumConcurrentPreparations = max(1, maximumConcurrentPreparations)
        self.maximumEstimatedPreparationBytes = max(0, maximumEstimatedPreparationBytes)
        self.neighborPredictionHorizon = normalizedHorizon
        self.directionalVelocityThreshold = normalizedDirectionalThreshold
        self.fastVelocityThreshold = fastVelocityThreshold.isFinite
            ? max(normalizedDirectionalThreshold, fastVelocityThreshold)
            : normalizedDirectionalThreshold
        self.cancellationDeadline = max(.zero, cancellationDeadline)
    }
}

/// A deterministic transition from one feed residency plan to the next.
public struct FeedPlan: Hashable, Sendable {
    public enum Disposition: Hashable, Sendable {
        case accepted
        case ignoredStaleSignal
    }

    public enum Role: Int, Hashable, Sendable {
        case focused
        case visible
        case predicted
        case neighbor
    }

    public struct Entry: Hashable, Sendable {
        public let itemID: FeedItemID
        public let role: Role
        public let estimatedPreparationBytes: Int

        public init(
            itemID: FeedItemID,
            role: Role,
            estimatedPreparationBytes: Int
        ) {
            self.itemID = itemID
            self.role = role
            self.estimatedPreparationBytes = max(0, estimatedPreparationBytes)
        }
    }

    public struct Cancellation: Hashable, Sendable {
        public let itemID: FeedItemID
        public let requestedAt: Duration
        public let deadline: Duration

        public init(itemID: FeedItemID, requestedAt: Duration, deadline: Duration) {
            self.itemID = itemID
            self.requestedAt = requestedAt
            self.deadline = deadline
        }
    }

    public let generation: FeedNavigationGeneration
    public let disposition: Disposition
    public let desiredEntries: [Entry]
    public let preparations: [Entry]
    public let cancellations: [Cancellation]
    public let estimatedPreparationBytes: Int

    public var desiredItemIDs: Set<FeedItemID> {
        Set(desiredEntries.map(\.itemID))
    }

    init(
        generation: FeedNavigationGeneration,
        disposition: Disposition,
        desiredEntries: [Entry],
        preparations: [Entry],
        cancellations: [Cancellation]
    ) {
        self.generation = generation
        self.disposition = disposition
        self.desiredEntries = desiredEntries
        self.preparations = preparations
        self.cancellations = cancellations
        self.estimatedPreparationBytes = desiredEntries.reduce(into: 0) { total, entry in
            total += entry.estimatedPreparationBytes
        }
    }
}
