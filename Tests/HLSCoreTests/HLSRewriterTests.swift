import XCTest
@testable import HLSCore

final class HLSRewriterTests: XCTestCase {
    private let playlist = MediaPlaylist(
        targetDuration: 4,
        mediaSequence: 1,
        segments: [
            HLSSegment(url: URL(string: "https://cdn.test/1.ts")!, duration: 4, sequence: 1),
            HLSSegment(url: URL(string: "https://cdn.test/2.ts")!, duration: 4, sequence: 2),
        ]
    )

    func testHideUntilBufferedSkipsSegments() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [1], prefetchDepthSeconds: 4)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            hideUntilBuffered: true
        )

        let output = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("segment-1"))
        XCTAssertFalse(output.contains("segment-2"), "Unbuffered segment should stay hidden.")
    }

    func testLowLatencyOptionsEmitServerControlAndPrefetch() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [], prefetchDepthSeconds: 0)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            hideUntilBuffered: true,
            lowLatencyOptions: .init(
                canSkipUntil: 6,
                partHoldBack: 0.5,
                allowBlockingReload: true,
                prefetchHintCount: 1,
                enableDeltaUpdates: true
            )
        )

        let output = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("#EXT-X-SERVER-CONTROL"))
        XCTAssertTrue(output.contains("#EXT-X-PART-INF"))
        XCTAssertTrue(output.contains("#EXT-X-PREFETCH"))
        XCTAssertTrue(output.contains("#EXT-X-SKIP"))
    }

    func testArtificialBandwidthInjection() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [1, 2], prefetchDepthSeconds: 8)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            artificialBandwidth: 1_500_000
        )

        let output = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("com.hlsproxy.bandwidth"))
    }

    func testOmitsEndListWhenSegmentsAreHidden() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [], prefetchDepthSeconds: 0)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            hideUntilBuffered: true
        )

        let output = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        XCTAssertFalse(output.contains("#EXT-X-ENDLIST"))
    }

    func testMediaSequenceAdvancesWithPlayhead() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [], prefetchDepthSeconds: 0, playedThroughSequence: 10)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            hideUntilBuffered: true
        )

        let output = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("#EXT-X-MEDIA-SEQUENCE:7"), "Playlist should slide window forward when playhead advances")
    }
}
