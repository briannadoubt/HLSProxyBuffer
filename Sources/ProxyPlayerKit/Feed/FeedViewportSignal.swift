import Foundation

/// A monotonically increasing focus/navigation epoch.
///
/// Work started for an older generation must not publish into a newer one.
public struct FeedNavigationGeneration: RawRepresentable, Hashable, Codable,
    Comparable, Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Framework-neutral visibility for an item at one observation instant.
public struct FeedItemVisibility: Hashable, Sendable {
    public let itemID: FeedItemID

    /// Visible fraction in the closed range `0...1`.
    public let fraction: Double

    /// Signed distance from the viewport center, measured in viewport lengths.
    public let distanceInViewports: Double

    public init(
        itemID: FeedItemID,
        fraction: Double,
        distanceInViewports: Double
    ) {
        self.itemID = itemID
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.distanceInViewports = distanceInViewports.isFinite
            ? distanceInViewports
            : 0
    }
}

/// An application or UI adapter prediction for an imminent destination.
public struct FeedDestinationPrediction: Hashable, Sendable {
    public let itemID: FeedItemID
    public let confidence: Double

    public init(itemID: FeedItemID, confidence: Double) {
        self.itemID = itemID
        self.confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
    }
}

/// A UI-independent snapshot used to plan automatic playback work.
///
/// UIKit, SwiftUI, AppKit, and custom renderers translate their geometry into
/// this value. `observedAt` is elapsed monotonic time from the owning session's
/// injected clock; wall-clock time must not drive cancellation decisions.
public struct FeedViewportSignal: Hashable, Sendable {
    public let generation: FeedNavigationGeneration
    public let focusedItemID: FeedItemID?
    public let visibleItems: [FeedItemVisibility]

    /// Signed velocity in viewport lengths per second. Positive values move
    /// toward increasing positions in the ordered item collection.
    public let velocityInViewportsPerSecond: Double

    public let predictedDestinations: [FeedDestinationPrediction]
    public let observedAt: Duration

    public init(
        generation: FeedNavigationGeneration,
        focusedItemID: FeedItemID?,
        visibleItems: [FeedItemVisibility],
        velocityInViewportsPerSecond: Double = 0,
        predictedDestinations: [FeedDestinationPrediction] = [],
        observedAt: Duration
    ) {
        self.generation = generation
        self.focusedItemID = focusedItemID
        self.visibleItems = visibleItems
        self.velocityInViewportsPerSecond = velocityInViewportsPerSecond.isFinite
            ? velocityInViewportsPerSecond
            : 0
        self.predictedDestinations = predictedDestinations
        self.observedAt = observedAt
    }
}
