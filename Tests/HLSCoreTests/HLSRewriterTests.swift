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

    private var encryptedPlaylist: MediaPlaylist {
        let key = HLSKey(
            method: .aes128,
            uri: URL(string: "https://keys.test/aes.key")!,
            keyFormat: "com.apple.streamingkeydelivery",
            keyFormatVersions: ["1"]
        )
        let encryption = SegmentEncryption(key: key, initializationVector: "0x1234")
        let map = MediaInitializationMap(
            uri: URL(string: "https://cdn.test/init.mp4")!,
            byteRange: 0...127
        )
        return MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(
                    url: URL(string: "https://cdn.test/enc1.ts")!,
                    duration: 4,
                    sequence: 1,
                    encryption: encryption,
                    initializationMap: map
                ),
                HLSSegment(
                    url: URL(string: "https://cdn.test/enc2.ts")!,
                    duration: 4,
                    sequence: 2,
                    encryption: encryption,
                    initializationMap: map
                )
            ],
            sessionKeys: [
                HLSKey(method: .sampleAES, uri: URL(string: "skd://session")!, keyFormat: "com.apple", keyFormatVersions: ["1"])
            ]
        )
    }

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

    func testNamespacedSegmentsProduceUniqueKeys() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [1], prefetchDepthSeconds: 4)
        let config = HLSRewriteConfiguration(proxyBaseURL: URL(string: "http://127.0.0.1:8080")!)
        let output = rewriter.rewrite(
            mediaPlaylist: playlist,
            config: config,
            bufferState: bufferState,
            namespace: "audio-main"
        )
        XCTAssertTrue(output.contains("audio-main-segment-1"))
    }

    func testEmitsEncryptionMetadata() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [1, 2], prefetchDepthSeconds: 8)
        let config = HLSRewriteConfiguration(proxyBaseURL: URL(string: "http://127.0.0.1:8080")!)

        let output = rewriter.rewrite(mediaPlaylist: encryptedPlaylist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES"))
        XCTAssertTrue(output.contains("KEYFORMAT=\"com.apple.streamingkeydelivery\""))
        XCTAssertTrue(output.contains("IV=0x1234"))
    }

    func testRewritesKeyURIWhenResolverProvided() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [1], prefetchDepthSeconds: 4)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            keyURLResolver: { _ in URL(string: "http://127.0.0.1:8080/assets/keys/abc")! }
        )

        let output = rewriter.rewrite(mediaPlaylist: encryptedPlaylist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("URI=\"http://127.0.0.1:8080/assets/keys/abc\""))
        XCTAssertFalse(output.contains("https://keys.test"))
    }

    func testEmitsInitializationMap() {
        let rewriter = HLSRewriter()
        let bufferState = BufferState(readySequences: [1], prefetchDepthSeconds: 4)
        let config = HLSRewriteConfiguration(proxyBaseURL: URL(string: "http://127.0.0.1:8080")!)

        let output = rewriter.rewrite(mediaPlaylist: encryptedPlaylist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("#EXT-X-MAP:URI=\"https://cdn.test/init.mp4\",BYTERANGE=128@0"))
    }
}
