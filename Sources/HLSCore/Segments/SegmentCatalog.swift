import Foundation

public actor SegmentCatalog {
    private var segments: [Int: HLSSegment] = [:]
    private var playlist: MediaPlaylist?

    public init() {}

    public func update(with playlist: MediaPlaylist) {
        self.playlist = playlist
        segments = playlist.segments.reduce(into: [:]) { result, segment in
            result[segment.sequence] = segment
        }
    }

    public func segment(forSequence sequence: Int) -> HLSSegment? {
        segments[sequence]
    }

    public func currentPlaylist() -> MediaPlaylist? {
        playlist
    }
}
