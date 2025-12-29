import Foundation

/// Represents a multi-clip playlist that can concatenate multiple HLS streams
public struct MultiClipPlaylist: Sendable {
    public enum ClipType: Sendable {
        case content
        case preRoll
        case midRoll
        case postRoll
    }

    public struct Clip: Sendable, Identifiable {
        public let id: String
        public let type: ClipType
        public let playlist: MediaPlaylist
        public let duration: TimeInterval
        public let startOffset: TimeInterval

        public init(
            id: String = UUID().uuidString,
            type: ClipType,
            playlist: MediaPlaylist,
            duration: TimeInterval? = nil,
            startOffset: TimeInterval = 0
        ) {
            self.id = id
            self.type = type
            self.playlist = playlist
            self.duration = duration ?? playlist.segments.reduce(0) { $0 + $1.duration }
            self.startOffset = startOffset
        }
    }

    public struct InsertionPoint: Sendable {
        public let timeOffset: TimeInterval
        public let clip: Clip

        public init(timeOffset: TimeInterval, clip: Clip) {
            self.timeOffset = timeOffset
            self.clip = clip
        }
    }

    public private(set) var clips: [Clip]
    public private(set) var insertionPoints: [InsertionPoint]
    public private(set) var totalDuration: TimeInterval

    public init(clips: [Clip] = [], insertionPoints: [InsertionPoint] = []) {
        self.clips = clips
        self.insertionPoints = insertionPoints
        self.totalDuration = clips.reduce(0) { $0 + $1.duration }
    }

    /// Adds a clip to the end of the playlist
    public mutating func appendClip(_ clip: Clip) {
        clips.append(clip)
        totalDuration += clip.duration
    }

    /// Inserts a clip at a specific time offset
    public mutating func insertClip(_ clip: Clip, at timeOffset: TimeInterval) {
        insertionPoints.append(InsertionPoint(timeOffset: timeOffset, clip: clip))
        insertionPoints.sort { $0.timeOffset < $1.timeOffset }
    }

    /// Inserts a mid-roll ad at the specified time
    public mutating func insertMidRoll(_ adPlaylist: MediaPlaylist, at timeOffset: TimeInterval) {
        let clip = Clip(type: .midRoll, playlist: adPlaylist)
        insertClip(clip, at: timeOffset)
    }

    /// Adds a pre-roll ad
    public mutating func addPreRoll(_ adPlaylist: MediaPlaylist) {
        let clip = Clip(type: .preRoll, playlist: adPlaylist)
        clips.insert(clip, at: 0)
        totalDuration += clip.duration
    }

    /// Adds a post-roll ad
    public mutating func addPostRoll(_ adPlaylist: MediaPlaylist) {
        let clip = Clip(type: .postRoll, playlist: adPlaylist)
        clips.append(clip)
        totalDuration += clip.duration
    }

    /// Returns the clip and local time for a given absolute time
    public func clipAt(absoluteTime: TimeInterval) -> (clip: Clip, localTime: TimeInterval)? {
        var accumulatedTime: TimeInterval = 0

        // Check for insertion points
        for insertion in insertionPoints {
            if absoluteTime >= insertion.timeOffset &&
               absoluteTime < insertion.timeOffset + insertion.clip.duration {
                return (insertion.clip, absoluteTime - insertion.timeOffset)
            }
        }

        // Check main clips
        for clip in clips {
            if absoluteTime >= accumulatedTime && absoluteTime < accumulatedTime + clip.duration {
                return (clip, absoluteTime - accumulatedTime)
            }
            accumulatedTime += clip.duration
        }

        return nil
    }

    /// Generates a combined manifest with all clips
    public func generateManifest(baseURL: URL) -> String {
        var manifest = "#EXTM3U\n"
        manifest += "#EXT-X-VERSION:6\n"
        manifest += "#EXT-X-TARGETDURATION:\(maxSegmentDuration())\n"
        manifest += "#EXT-X-MEDIA-SEQUENCE:0\n"

        var segmentIndex = 0
        var insertionIndex = 0
        var currentTime: TimeInterval = 0

        for (clipIndex, clip) in clips.enumerated() {
            // Check for insertion points
            while insertionIndex < insertionPoints.count &&
                  insertionPoints[insertionIndex].timeOffset <= currentTime {
                let insertion = insertionPoints[insertionIndex]
                manifest += "#EXT-X-DISCONTINUITY\n"
                manifest += generateClipSegments(insertion.clip, startIndex: &segmentIndex, baseURL: baseURL)
                manifest += "#EXT-X-DISCONTINUITY\n"
                insertionIndex += 1
            }

            if clipIndex > 0 {
                manifest += "#EXT-X-DISCONTINUITY\n"
            }

            manifest += generateClipSegments(clip, startIndex: &segmentIndex, baseURL: baseURL)
            currentTime += clip.duration
        }

        if !isLive {
            manifest += "#EXT-X-ENDLIST\n"
        }

        return manifest
    }

    private func generateClipSegments(_ clip: Clip, startIndex: inout Int, baseURL: URL) -> String {
        var result = ""
        for segment in clip.playlist.segments {
            result += "#EXTINF:\(String(format: "%.3f", segment.duration)),\n"
            result += "\(baseURL.appendingPathComponent("segments/\(clip.id)/\(startIndex).ts"))\n"
            startIndex += 1
        }
        return result
    }

    private func maxSegmentDuration() -> Int {
        var maxDuration: TimeInterval = 0
        for clip in clips {
            for segment in clip.playlist.segments {
                maxDuration = max(maxDuration, segment.duration)
            }
        }
        for insertion in insertionPoints {
            for segment in insertion.clip.playlist.segments {
                maxDuration = max(maxDuration, segment.duration)
            }
        }
        return Int(ceil(maxDuration))
    }

    private var isLive: Bool {
        clips.last?.playlist.isLive ?? false
    }
}

// MARK: - Ad Insertion

public struct AdInsertionManager: Sendable {
    public struct AdBreak: Sendable {
        public let id: String
        public let timeOffset: TimeInterval
        public let duration: TimeInterval
        public let ads: [MediaPlaylist]
        public var isWatched: Bool

        public init(
            id: String = UUID().uuidString,
            timeOffset: TimeInterval,
            duration: TimeInterval,
            ads: [MediaPlaylist],
            isWatched: Bool = false
        ) {
            self.id = id
            self.timeOffset = timeOffset
            self.duration = duration
            self.ads = ads
            self.isWatched = isWatched
        }
    }

    public struct AdSchedule: Sendable {
        public var preRolls: [MediaPlaylist]
        public var midRolls: [AdBreak]
        public var postRolls: [MediaPlaylist]

        public init(
            preRolls: [MediaPlaylist] = [],
            midRolls: [AdBreak] = [],
            postRolls: [MediaPlaylist] = []
        ) {
            self.preRolls = preRolls
            self.midRolls = midRolls
            self.postRolls = postRolls
        }

        public var totalAdDuration: TimeInterval {
            let preRollDuration = preRolls.reduce(0) { $0 + $1.duration }
            let midRollDuration = midRolls.reduce(0) { $0 + $1.duration }
            let postRollDuration = postRolls.reduce(0) { $0 + $1.duration }
            return preRollDuration + midRollDuration + postRollDuration
        }
    }

    public let schedule: AdSchedule

    public init(schedule: AdSchedule) {
        self.schedule = schedule
    }

    /// Applies the ad schedule to a content playlist
    public func applyTo(content: MediaPlaylist) -> MultiClipPlaylist {
        var multiClip = MultiClipPlaylist()

        // Add pre-rolls
        for preRoll in schedule.preRolls {
            multiClip.addPreRoll(preRoll)
        }

        // Add main content
        let contentClip = MultiClipPlaylist.Clip(type: .content, playlist: content)
        multiClip.appendClip(contentClip)

        // Add mid-rolls
        for adBreak in schedule.midRolls {
            for ad in adBreak.ads {
                multiClip.insertMidRoll(ad, at: adBreak.timeOffset)
            }
        }

        // Add post-rolls
        for postRoll in schedule.postRolls {
            multiClip.addPostRoll(postRoll)
        }

        return multiClip
    }

    /// Checks if the current playback position is within an ad break
    public func isInAdBreak(at time: TimeInterval) -> AdBreak? {
        for midRoll in schedule.midRolls {
            if time >= midRoll.timeOffset && time < midRoll.timeOffset + midRoll.duration {
                return midRoll
            }
        }
        return nil
    }
}

// MARK: - VOD to Live Detection

public struct StreamTypeDetector: Sendable {
    public enum StreamType: Sendable {
        case vod
        case live
        case event
        case unknown
    }

    public static func detect(from playlist: MediaPlaylist) -> StreamType {
        // Check for explicit playlist type
        if let typeTag = playlist.playlistType {
            switch typeTag.lowercased() {
            case "vod":
                return .vod
            case "event":
                return .event
            default:
                break
            }
        }

        // Check for ENDLIST tag
        if playlist.hasEndList {
            return .vod
        }

        // Live streams typically have a shorter segment window
        if playlist.segments.count < 10 && !playlist.hasEndList {
            return .live
        }

        // Event streams grow over time but don't remove segments
        if !playlist.hasEndList && playlist.segments.count > 10 {
            return .event
        }

        return .unknown
    }

    public static func detectTransition(
        previous: MediaPlaylist?,
        current: MediaPlaylist
    ) -> (from: StreamType, to: StreamType)? {
        guard let previous = previous else { return nil }

        let previousType = detect(from: previous)
        let currentType = detect(from: current)

        if previousType != currentType {
            return (previousType, currentType)
        }

        return nil
    }
}

// MARK: - DVR / Catch-up Support

public struct DVRController: Sendable {
    public struct DVRWindow: Sendable {
        public let startTime: Date
        public let endTime: Date
        public let duration: TimeInterval
        public let startSequence: Int
        public let endSequence: Int

        public var isAtLiveEdge: Bool {
            Date().timeIntervalSince(endTime) < 10 // Within 10 seconds of live
        }
    }

    public let windowDuration: TimeInterval
    public private(set) var currentWindow: DVRWindow?

    public init(windowDuration: TimeInterval = 3600) { // 1 hour default
        self.windowDuration = windowDuration
    }

    public mutating func updateWindow(from playlist: MediaPlaylist, liveEdgeTime: Date) {
        let totalDuration = playlist.segments.reduce(0) { $0 + $1.duration }
        let startTime = liveEdgeTime.addingTimeInterval(-min(totalDuration, windowDuration))

        currentWindow = DVRWindow(
            startTime: startTime,
            endTime: liveEdgeTime,
            duration: min(totalDuration, windowDuration),
            startSequence: playlist.mediaSequence,
            endSequence: playlist.mediaSequence + playlist.segments.count - 1
        )
    }

    public func seekableRange() -> ClosedRange<TimeInterval>? {
        guard let window = currentWindow else { return nil }
        return 0...window.duration
    }

    public func sequenceForTime(_ time: TimeInterval, in playlist: MediaPlaylist) -> Int? {
        var accumulatedTime: TimeInterval = 0
        for (index, segment) in playlist.segments.enumerated() {
            if time >= accumulatedTime && time < accumulatedTime + segment.duration {
                return playlist.mediaSequence + index
            }
            accumulatedTime += segment.duration
        }
        return nil
    }

    public func timeForSequence(_ sequence: Int, in playlist: MediaPlaylist) -> TimeInterval? {
        let relativeSequence = sequence - playlist.mediaSequence
        guard relativeSequence >= 0 && relativeSequence < playlist.segments.count else {
            return nil
        }

        var time: TimeInterval = 0
        for i in 0..<relativeSequence {
            time += playlist.segments[i].duration
        }
        return time
    }

    public func jumpToLive() -> Int? {
        currentWindow?.endSequence
    }
}

// MARK: - MediaPlaylist Extensions

private extension MediaPlaylist {
    var playlistType: String? {
        // This would be parsed from #EXT-X-PLAYLIST-TYPE
        nil
    }

    var hasEndList: Bool {
        !isLive
    }

    var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }
}
