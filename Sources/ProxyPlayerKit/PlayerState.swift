import Foundation
import HLSCore

/// Typed, fixed-size live playback diagnostics exposed through Observation and
/// ``ProxyHLSPlayer/stateUpdates()``.
public struct LivePlaybackState: Sendable, Equatable {
    public enum Seekability: Sendable, Equatable {
        /// The manifest is live, but it cannot produce a valid seek window.
        case unavailable(HLSLiveTimeline.UnavailabilityReason)
        /// A valid live presentation with no meaningful DVR history yet.
        case liveOnly
        /// The caller may seek this many seconds behind the live edge.
        case dvr(maximumSecondsBehindLiveEdge: TimeInterval)
    }

    public let seekability: Seekability
    public let window: HLSLiveWindow?
    public let liveEdgeDistanceSeconds: TimeInterval?
    public let playheadProgramDateTime: Date?

    public init(
        seekability: Seekability,
        window: HLSLiveWindow? = nil,
        liveEdgeDistanceSeconds: TimeInterval? = nil,
        playheadProgramDateTime: Date? = nil
    ) {
        self.seekability = seekability
        self.window = window
        self.liveEdgeDistanceSeconds = liveEdgeDistanceSeconds
        self.playheadProgramDateTime = playheadProgramDateTime
    }

    /// `true` when playback is within the playlist's recommended hold-back.
    public var isAtLiveEdge: Bool {
        guard let window, let liveEdgeDistanceSeconds else { return false }
        return liveEdgeDistanceSeconds <= window.recommendedLiveEdgeDistanceSeconds + 0.25
    }
}

public enum LivePlaybackControlError: Error, Sendable, Equatable, LocalizedError {
    case notLive
    case seekUnavailable
    case invalidDistance
    case outsideDVRWindow(requested: TimeInterval, maximum: TimeInterval)
    case seekRejected

    public var errorDescription: String? {
        switch self {
        case .notLive:
            "The current item is not a live stream"
        case .seekUnavailable:
            "The live stream does not currently expose a seekable range"
        case .invalidDistance:
            "The distance behind live must be finite and nonnegative"
        case .outsideDVRWindow(let requested, let maximum):
            "Requested \(requested) seconds behind live, but the window contains \(maximum) seconds"
        case .seekRejected:
            "AVPlayer rejected the live seek"
        }
    }
}

public struct PlayerState: Sendable, Equatable {
    public enum Status: Equatable, Sendable {
        case idle
        case buffering
        case ready
        case failed(String)
    }

    public let status: Status
    public let bufferDepthSeconds: TimeInterval
    public let qualityDescription: String
    public let livePlayback: LivePlaybackState?

    public init(
        status: Status = .idle,
        bufferDepthSeconds: TimeInterval = 0,
        qualityDescription: String = "auto",
        livePlayback: LivePlaybackState? = nil
    ) {
        self.status = status
        self.bufferDepthSeconds = bufferDepthSeconds
        self.qualityDescription = qualityDescription
        self.livePlayback = livePlayback
    }
}
