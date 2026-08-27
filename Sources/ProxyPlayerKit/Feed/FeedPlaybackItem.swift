import Foundation

/// A stable application-defined identity for one item in a playback feed.
public struct FeedItemID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }
}

/// The timeline behavior of a single HLS stream.
public enum FeedStreamKind: String, Codable, Sendable {
    case videoOnDemand
    case live
}

/// A source the automatic playback engine can own and prepare.
///
/// Clip sequences are stitched only when they satisfy the compatibility
/// contract. Callers provide sources, but never construct proxy URLs or player
/// queues themselves.
public enum FeedPlaybackSource: Hashable, Sendable {
    case stream(url: URL, kind: FeedStreamKind)
    case clips([URL])
}

/// One ordered source and its conservative planning estimate.
public struct FeedPlaybackItem: Identifiable, Hashable, Sendable {
    public let id: FeedItemID
    public let source: FeedPlaybackSource

    /// Estimated bytes required to make the item immediately playable.
    ///
    /// This is a planning reservation, not a cache size promise. The feed
    /// policy applies hard cache and resident-memory limits separately.
    public let estimatedPreparationBytes: Int

    /// A stable application priority. Higher values win otherwise equal ranks.
    public let priority: Int

    public init(
        id: FeedItemID,
        source: FeedPlaybackSource,
        estimatedPreparationBytes: Int,
        priority: Int = 0
    ) {
        self.id = id
        self.source = source
        self.estimatedPreparationBytes = max(0, estimatedPreparationBytes)
        self.priority = priority
    }
}
