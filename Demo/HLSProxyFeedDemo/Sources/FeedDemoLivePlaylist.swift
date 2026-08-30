import Foundation

/// A deterministic rolling window over recorded media, not a live broadcast.
enum FeedDemoLivePlaylist {
    struct Window: Sendable {
        let text: String
        let sequence: Int
    }

    static func make(
        library: FeedDemoMediaLibrary,
        elapsedSeconds: Double,
        maximumSegmentCount: Int = 6
    ) -> Window? {
        guard let clip = library.continuousClip,
              let rendition = clip.renditions.first(where: { $0.id == "360p" }),
              let duration = rendition.segmentDurations.first,
              duration > 0, elapsedSeconds.isFinite,
              !rendition.segmentPaths.isEmpty
        else { return nil }
        let count = rendition.segmentPaths.count
        let sequence = Int(min(Double(Int.max / 2), max(0, elapsedSeconds / duration)))
        let prefix = "/\(library.catalog.corpusVersion)/"
        let target = Int(ceil(rendition.segmentDurations.max() ?? duration))
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MEDIA-SEQUENCE:\(sequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(sequence / count)",
            "#EXT-X-MAP:URI=\"\(prefix)\(rendition.initializationPath)\"",
        ]
        for offset in 0..<min(count, max(1, maximumSegmentCount)) {
            let position = sequence + offset
            if offset > 0 && position.isMultiple(of: count) { lines.append("#EXT-X-DISCONTINUITY") }
            let index = position % count
            lines.append("#EXTINF:\(rendition.segmentDurations[index]),")
            lines.append(prefix + rendition.segmentPaths[index])
        }
        return Window(text: lines.joined(separator: "\n") + "\n", sequence: sequence)
    }
}
