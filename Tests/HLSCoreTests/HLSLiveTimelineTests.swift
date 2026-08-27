import XCTest
@testable import HLSCore

final class HLSLiveTimelineTests: XCTestCase {
    private let parser = HLSParser()

    func testDerivesSlidingWindowAndProgramDateTimeAcrossDiscontinuity() throws {
        let first = try mediaPlaylist("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:100
        #EXT-X-DISCONTINUITY-SEQUENCE:8
        #EXT-X-PROGRAM-DATE-TIME:2026-08-27T05:00:00.000Z
        #EXTINF:4,
        100.m4s
        #EXTINF:4,
        101.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-PROGRAM-DATE-TIME:2026-08-27T05:00:08.000Z
        #EXTINF:4,
        102.m4s
        """)
        let slid = try mediaPlaylist("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:101
        #EXT-X-DISCONTINUITY-SEQUENCE:8
        #EXTINF:4,
        101.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-PROGRAM-DATE-TIME:2026-08-27T05:00:08.000Z
        #EXTINF:4,
        102.m4s
        #EXTINF:4,
        103.m4s
        """)

        let firstWindow = try availableWindow(first)
        XCTAssertEqual(firstWindow.mediaSequenceRange, 100...102)
        XCTAssertEqual(firstWindow.durationSeconds, 12)
        XCTAssertEqual(firstWindow.recommendedLiveEdgeDistanceSeconds, 12)
        XCTAssertEqual(firstWindow.discontinuitySequence, 8)
        XCTAssertEqual(firstWindow.discontinuityCount, 1)
        XCTAssertEqual(firstWindow.programDateTimeRange?.lowerBound, isoDate("2026-08-27T05:00:00.000Z"))
        XCTAssertEqual(firstWindow.programDateTimeRange?.upperBound, isoDate("2026-08-27T05:00:12.000Z"))

        let slidWindow = try availableWindow(slid)
        XCTAssertEqual(slidWindow.mediaSequenceRange, 101...103)
        XCTAssertEqual(slidWindow.durationSeconds, 12)
        XCTAssertEqual(slidWindow.discontinuityCount, 1)
        XCTAssertEqual(slidWindow.programDateTimeRange?.lowerBound, isoDate("2026-08-27T05:00:04.000Z"))
        XCTAssertEqual(slidWindow.programDateTimeRange?.upperBound, isoDate("2026-08-27T05:00:16.000Z"))
    }

    func testIncludesTrailingPartsAndPrefersPartHoldBack() throws {
        let playlist = try mediaPlaylist("""
        #EXTM3U
        #EXT-X-VERSION:9
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:50
        #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,HOLD-BACK=6,PART-HOLD-BACK=1.5
        #EXT-X-PART-INF:PART-TARGET=0.5
        #EXTINF:4,
        50.m4s
        #EXTINF:4,
        51.m4s
        #EXT-X-PART:DURATION=0.5,URI="52.0.m4s",INDEPENDENT=YES
        #EXT-X-PART:DURATION=0.5,URI="52.1.m4s"
        """)

        let window = try availableWindow(playlist)
        XCTAssertEqual(window.mediaSequenceRange, 50...52)
        XCTAssertEqual(window.completeSegmentDurationSeconds, 8)
        XCTAssertEqual(window.durationSeconds, 9)
        XCTAssertEqual(window.recommendedLiveEdgeDistanceSeconds, 1.5)
        XCTAssertTrue(window.hasPartialSegments)
        XCTAssertEqual(window.position(secondsBehindLiveEdge: 2), 7)
        XCTAssertEqual(window.position(secondsBehindLiveEdge: 100), 0)
    }

    func testClassifiesVODAndTypedUnavailableLiveWindows() throws {
        let vod = try mediaPlaylist("""
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        vod.ts
        #EXT-X-ENDLIST
        """)
        XCTAssertEqual(HLSLiveTimeline.state(for: vod), .videoOnDemand)

        let empty = MediaPlaylist(targetDuration: 4, segments: [])
        XCTAssertEqual(HLSLiveTimeline.state(for: empty), .unavailable(.emptyWindow))

        let invalid = MediaPlaylist(
            targetDuration: 4,
            segments: [HLSSegment(
                url: URL(string: "https://example.com/invalid.ts")!,
                duration: .nan,
                sequence: 9
            )]
        )
        XCTAssertEqual(
            HLSLiveTimeline.state(for: invalid),
            .unavailable(.invalidSegmentDuration(sequence: 9))
        )
    }

    private func mediaPlaylist(_ text: String) throws -> MediaPlaylist {
        let manifest = try parser.parse(text, baseURL: URL(string: "https://example.com/live.m3u8"))
        return try XCTUnwrap(manifest.mediaPlaylist)
    }

    private func availableWindow(_ playlist: MediaPlaylist) throws -> HLSLiveWindow {
        guard case .available(let window) = HLSLiveTimeline.state(for: playlist) else {
            XCTFail("Expected an available live window")
            throw URLError(.cannotParseResponse)
        }
        return window
    }

    private func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
