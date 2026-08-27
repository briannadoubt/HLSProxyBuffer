import Foundation
import HLSCore

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

/// Transport boundary for feed source manifests.
///
/// Production feeds are HTTPS-only by default. ``allowLoopbackHTTP`` exists
/// for deterministic local fixture servers and never permits cleartext URLs
/// on a remote host.
public enum HLSFeedSourceTransportPolicy: Sendable, Equatable {
    case secureOnly
    case allowLoopbackHTTP

    func allows(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" {
            return true
        }
        guard self == .allowLoopbackHTTP,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased()
        else {
            return false
        }
        if host == "localhost" || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.first == "127"
            && octets.allSatisfy { octet in
                guard let value = UInt8(octet) else { return false }
                return String(value) == octet
            }
    }

    var allowsInsecureManifests: Bool {
        self == .allowLoopbackHTTP
    }
}

/// One finite media-playlist clip plus the trusted decoder compatibility facts
/// required to join it directly into a single HLS timeline.
public struct ProxyPlaybackClip: Identifiable, Hashable, Sendable {
    public let id: String
    public let playlistURL: URL
    public let mediaSignature: HLSClipMediaSignature

    public init(
        id: String,
        playlistURL: URL,
        mediaSignature: HLSClipMediaSignature
    ) {
        self.id = id
        self.playlistURL = playlistURL
        self.mediaSignature = mediaSignature
    }
}

/// A source the automatic playback engine can own and prepare.
///
/// Clip sequences are stitched only when they satisfy the compatibility
/// contract. Callers provide sources, but never construct proxy URLs or player
/// queues themselves.
public enum FeedPlaybackSource: Hashable, Sendable {
    case stream(url: URL, kind: FeedStreamKind)
    /// Legacy untyped clip preparation. Prefer ``compatibleClips(_:)`` when
    /// the clips will be presented as one seamless playback timeline.
    case clips([URL])
    case compatibleClips([ProxyPlaybackClip])

    var hasEmptyClipSequence: Bool {
        switch self {
        case .stream:
            false
        case .clips(let urls):
            urls.isEmpty
        case .compatibleClips(let clips):
            clips.isEmpty
        }
    }
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
