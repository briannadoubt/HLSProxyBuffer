import Foundation

/// A validated, playlist-relative view of a live HLS window.
///
/// Times are expressed as distances within the current playlist window. This
/// keeps the model deterministic across sliding playlist updates while the
/// player maps those distances onto its current `seekableTimeRanges`.
public struct HLSLiveWindow: Sendable, Equatable {
    public let mediaSequenceRange: ClosedRange<Int>
    public let durationSeconds: TimeInterval
    public let completeSegmentDurationSeconds: TimeInterval
    public let recommendedLiveEdgeDistanceSeconds: TimeInterval
    public let programDateTimeRange: ClosedRange<Date>?
    public let discontinuitySequence: Int?
    public let discontinuityCount: Int
    public let hasPartialSegments: Bool

    public init(
        mediaSequenceRange: ClosedRange<Int>,
        durationSeconds: TimeInterval,
        completeSegmentDurationSeconds: TimeInterval,
        recommendedLiveEdgeDistanceSeconds: TimeInterval,
        programDateTimeRange: ClosedRange<Date>? = nil,
        discontinuitySequence: Int? = nil,
        discontinuityCount: Int = 0,
        hasPartialSegments: Bool = false
    ) {
        self.mediaSequenceRange = mediaSequenceRange
        self.durationSeconds = durationSeconds
        self.completeSegmentDurationSeconds = completeSegmentDurationSeconds
        self.recommendedLiveEdgeDistanceSeconds = recommendedLiveEdgeDistanceSeconds
        self.programDateTimeRange = programDateTimeRange
        self.discontinuitySequence = discontinuitySequence
        self.discontinuityCount = discontinuityCount
        self.hasPartialSegments = hasPartialSegments
    }

    /// Converts a distance behind the live edge into a playlist-relative time.
    public func position(secondsBehindLiveEdge: TimeInterval) -> TimeInterval {
        durationSeconds - min(max(0, secondsBehindLiveEdge), durationSeconds)
    }

    /// Returns the wall-clock time for a distance behind live when PDT is known.
    public func programDate(secondsBehindLiveEdge: TimeInterval) -> Date? {
        programDateTimeRange?.upperBound.addingTimeInterval(
            -min(max(0, secondsBehindLiveEdge), durationSeconds)
        )
    }
}

/// Deterministic live-window derivation shared by the player and feed engine.
public enum HLSLiveTimeline {
    public enum UnavailabilityReason: Sendable, Equatable {
        case emptyWindow
        case invalidSegmentDuration(sequence: Int)
        case invalidPartialDuration(sequence: Int, partIndex: Int)
    }

    public enum State: Sendable, Equatable {
        case videoOnDemand
        case unavailable(UnavailabilityReason)
        case available(HLSLiveWindow)
    }

    public static func state(for playlist: MediaPlaylist) -> State {
        guard !playlist.isEndlist else { return .videoOnDemand }
        guard !playlist.segments.isEmpty || !playlist.trailingParts.isEmpty else {
            return .unavailable(.emptyWindow)
        }

        for segment in playlist.segments where !segment.duration.isFinite || segment.duration <= 0 {
            return .unavailable(.invalidSegmentDuration(sequence: segment.sequence))
        }
        for part in playlist.segments.flatMap(\.parts) + playlist.trailingParts
        where !part.duration.isFinite || part.duration <= 0 {
            return .unavailable(.invalidPartialDuration(
                sequence: part.parentSequence,
                partIndex: part.partIndex
            ))
        }

        let completeDuration = playlist.segments.reduce(0) { $0 + $1.duration }
        // Parts nested under complete segments are already represented by the
        // parent EXTINF duration. Only trailing parts extend the live edge.
        let trailingDuration = playlist.trailingParts.reduce(0) { $0 + $1.duration }
        let duration = completeDuration + trailingDuration
        guard duration > 0, duration.isFinite else {
            return .unavailable(.emptyWindow)
        }

        let sequences = playlist.segments.map(\.sequence)
            + playlist.trailingParts.map(\.parentSequence)
        guard let firstSequence = sequences.min(), let lastSequence = sequences.max() else {
            return .unavailable(.emptyWindow)
        }

        let hasPartialSegments = !playlist.trailingParts.isEmpty
            || playlist.segments.contains { !$0.parts.isEmpty }
        let targetLatency = recommendedLiveEdgeDistance(
            playlist: playlist,
            hasPartialSegments: hasPartialSegments,
            windowDuration: duration
        )
        let programDateRange = programDateTimeRange(
            playlist: playlist,
            totalDuration: duration
        )
        let discontinuityCount = playlist.segments.reduce(into: 0) { count, segment in
            count += segment.metadataTags.reduce(into: 0) { tagCount, tag in
                if tag == "#EXT-X-DISCONTINUITY" { tagCount += 1 }
            }
        }

        return .available(HLSLiveWindow(
            mediaSequenceRange: firstSequence...lastSequence,
            durationSeconds: duration,
            completeSegmentDurationSeconds: completeDuration,
            recommendedLiveEdgeDistanceSeconds: targetLatency,
            programDateTimeRange: programDateRange,
            discontinuitySequence: playlist.discontinuitySequence,
            discontinuityCount: discontinuityCount,
            hasPartialSegments: hasPartialSegments
        ))
    }

    private static func recommendedLiveEdgeDistance(
        playlist: MediaPlaylist,
        hasPartialSegments: Bool,
        windowDuration: TimeInterval
    ) -> TimeInterval {
        let value: TimeInterval
        if hasPartialSegments {
            value = playlist.serverControl?.partHoldBack
                ?? playlist.serverControl?.holdBack
                ?? playlist.partTargetDuration.map { $0 * 3 }
                ?? playlist.targetDuration.map { $0 * 3 }
                ?? 0
        } else {
            value = playlist.serverControl?.holdBack
                ?? playlist.targetDuration.map { $0 * 3 }
                ?? 0
        }
        guard value.isFinite else { return 0 }
        return min(max(0, value), windowDuration)
    }

    private static func programDateTimeRange(
        playlist: MediaPlaylist,
        totalDuration: TimeInterval
    ) -> ClosedRange<Date>? {
        var elapsed: TimeInterval = 0
        var latestAnchor: (date: Date, elapsed: TimeInterval)?
        for segment in playlist.segments {
            for tag in segment.metadataTags {
                guard tag.hasPrefix(programDateTimePrefix) else { continue }
                let value = String(tag.dropFirst(programDateTimePrefix.count))
                if let date = parseProgramDate(value) {
                    latestAnchor = (date, elapsed)
                }
            }
            elapsed += segment.duration
        }
        guard let latestAnchor else { return nil }
        let start = latestAnchor.date.addingTimeInterval(-latestAnchor.elapsed)
        return start...start.addingTimeInterval(totalDuration)
    }

    private static func parseProgramDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static let programDateTimePrefix = "#EXT-X-PROGRAM-DATE-TIME:"
}
