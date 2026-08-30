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

    func testLowLatencyOptionsEmitVersionTenWithoutNonstandardPrefetchTags() {
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

        let llPlaylist = MediaPlaylist(
            targetDuration: playlist.targetDuration,
            mediaSequence: playlist.mediaSequence,
            segments: playlist.segments,
            partTargetDuration: 0.5
        )

        let output = rewriter.rewrite(mediaPlaylist: llPlaylist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("#EXT-X-SERVER-CONTROL"))
        XCTAssertTrue(output.contains("#EXT-X-PART-INF"))
        XCTAssertTrue(output.contains("#EXT-X-VERSION:10"))
        XCTAssertFalse(output.contains("#EXT-X-PREFETCH:"))
        XCTAssertFalse(output.contains("#EXT-X-PREFETCH-DISTANCE"))
        XCTAssertFalse(output.contains("#EXT-X-SKIP"))
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

    func testExplicitVODRemainsCompleteAndImmutableAcrossBufferStates() throws {
        let vod = MediaPlaylist(
            targetDuration: 4, mediaSequence: 1, segments: playlist.segments,
            isEndlist: true, playlistType: "VOD"
        )
        let configuration = HLSRewriteConfiguration(
            proxyBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8080")),
            hideUntilBuffered: true
        )
        let states = [
            BufferState(readySequences: [], prefetchDepthSeconds: 0),
            BufferState(readySequences: [1], prefetchDepthSeconds: 4),
            BufferState(readySequences: [1, 2], prefetchDepthSeconds: 8),
            BufferState(readySequences: [], prefetchDepthSeconds: 0, playedThroughSequence: 10),
        ]
        let outputs = states.map {
            HLSRewriter().rewrite(mediaPlaylist: vod, config: configuration, bufferState: $0)
        }
        XCTAssertEqual(Set(outputs).count, 1, "VOD cannot change as buffering or playback advances")
        let output = try XCTUnwrap(outputs.first)
        XCTAssertTrue(output.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(output.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(output.contains("#EXT-X-MEDIA-SEQUENCE:1"))
        XCTAssertTrue(output.contains("segment-1"))
        XCTAssertTrue(output.contains("segment-2"))
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
        let map = try! XCTUnwrap(encryptedPlaylist.segments.first?.initializationMap)
        let localMapURL = config.initializationMapURL(for: map)
        XCTAssertTrue(output.contains("#EXT-X-MAP:URI=\"\(localMapURL.absoluteString)\",BYTERANGE=128@0"))
        XCTAssertFalse(output.contains("https://cdn.test/init.mp4"))
    }

    func testEmitsPartsPreloadHintsAndReports() {
        let rewriter = HLSRewriter()
        let part0 = HLSPartialSegment(
            parentSequence: 1,
            partIndex: 0,
            duration: 0.5,
            url: URL(string: "https://cdn.test/part0.ts")!,
            isIndependent: true
        )
        let part1 = HLSPartialSegment(
            parentSequence: 1,
            partIndex: 1,
            duration: 0.5,
            url: URL(string: "https://cdn.test/part1.ts")!
        )
        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.test/1.ts")!, duration: 4, sequence: 1, parts: [part0, part1]),
                HLSSegment(url: URL(string: "https://cdn.test/2.ts")!, duration: 4, sequence: 2)
            ],
            partTargetDuration: 0.5,
            serverControl: HLSServerControl(canSkipUntil: nil, canBlockReload: true, canSkipDateRanges: false, canPrefetch: false, holdBack: nil, partHoldBack: 1.5, partTarget: nil),
            preloadHints: [HLSPreloadHint(type: .part, uri: URL(string: "https://cdn.test/part2.ts")!, sequence: 2, partIndex: 2)],
            renditionReports: [HLSRenditionReport(uri: URL(string: "https://cdn.test/alt.m3u8")!, lastMediaSequence: 2, lastPartIndex: 1)]
        )

        let bufferState = BufferState(readySequences: [1], readyPartCounts: [1: 1], prefetchDepthSeconds: 1, partPrefetchDepthSeconds: 0.5)
        let config = HLSRewriteConfiguration(
            proxyBaseURL: URL(string: "http://127.0.0.1:8080")!,
            hideUntilBuffered: true,
            lowLatencyOptions: .init(canSkipUntil: 6, partHoldBack: 0.5, allowBlockingReload: true, prefetchHintCount: 1, enableDeltaUpdates: true),
            renditionReportURLResolver: { _ in
                URL(string: "http://127.0.0.1:8080/renditions/alternate.m3u8")!
            }
        )

        let output = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        XCTAssertTrue(output.contains("#EXT-X-PART-INF:PART-TARGET=0.500"))
        XCTAssertTrue(output.contains("CAN-BLOCK-RELOAD=YES"))
        XCTAssertTrue(output.contains("PART-HOLD-BACK=0.500"))
        XCTAssertTrue(output.contains("URI=\"\(config.partialSegmentURL(for: part0).absoluteString)\""))
        XCTAssertFalse(output.contains(config.partialSegmentURL(for: part1).absoluteString), "Second part should be hidden until buffered")
        let hint = try! XCTUnwrap(playlist.preloadHints.first)
        XCTAssertTrue(output.contains("URI=\"\(config.preloadHintURL(for: hint).absoluteString)\""))
        XCTAssertTrue(output.contains("#EXT-X-RENDITION-REPORT:URI=\"http://127.0.0.1:8080/renditions/alternate.m3u8\""))
        XCTAssertFalse(output.contains("https://cdn.test"))
    }

    func testEmitsMethodNoneWhenEncryptionEnds() {
        let key = HLSKey(method: .aes128, uri: URL(string: "https://keys.test/key")!)
        let playlist = MediaPlaylist(
            targetDuration: 4,
            segments: [
                HLSSegment(
                    url: URL(string: "https://cdn.test/encrypted.ts")!,
                    duration: 4,
                    sequence: 1,
                    encryption: SegmentEncryption(key: key)
                ),
                HLSSegment(url: URL(string: "https://cdn.test/clear.ts")!, duration: 4, sequence: 2)
            ]
        )
        let output = HLSRewriter().rewrite(
            mediaPlaylist: playlist,
            config: HLSRewriteConfiguration(proxyBaseURL: URL(string: "http://127.0.0.1:8080")!),
            bufferState: BufferState(readySequences: [1, 2])
        )
        XCTAssertTrue(output.contains("#EXT-X-KEY:METHOD=NONE"))
    }

    func testPartLevelKeyAndMapTransitionsRemainOrdered() throws {
        let keyA = SegmentEncryption(key: HLSKey(method: .aes128, uri: URL(string: "https://keys.test/a")!))
        let keyB = SegmentEncryption(key: HLSKey(method: .aes128, uri: URL(string: "https://keys.test/b")!))
        let mapA = MediaInitializationMap(uri: URL(string: "https://cdn.test/init-a.mp4")!)
        let mapB = MediaInitializationMap(uri: URL(string: "https://cdn.test/init-b.mp4")!)
        let partA = HLSPartialSegment(
            parentSequence: 1,
            partIndex: 0,
            duration: 0.5,
            url: URL(string: "https://cdn.test/a.m4s")!,
            encryption: keyA,
            initializationMap: mapA
        )
        let partB = HLSPartialSegment(
            parentSequence: 1,
            partIndex: 1,
            duration: 0.5,
            url: URL(string: "https://cdn.test/b.m4s")!,
            encryption: keyB,
            initializationMap: mapB
        )
        let media = MediaPlaylist(
            targetDuration: 2,
            segments: [
                HLSSegment(
                    url: URL(string: "https://cdn.test/complete.m4s")!,
                    duration: 2,
                    sequence: 1,
                    encryption: keyB,
                    initializationMap: mapB,
                    parts: [partA, partB]
                )
            ],
            partTargetDuration: 0.5
        )
        let config = HLSRewriteConfiguration(proxyBaseURL: URL(string: "http://127.0.0.1:8080")!)
        let output = HLSRewriter().rewrite(
            mediaPlaylist: media,
            config: config,
            bufferState: BufferState(readySequences: [1])
        )

        let firstMap = try XCTUnwrap(output.range(of: config.initializationMapURL(for: mapA).absoluteString))
        let firstPart = try XCTUnwrap(output.range(of: config.partialSegmentURL(for: partA).absoluteString))
        let secondMap = try XCTUnwrap(output.range(of: config.initializationMapURL(for: mapB).absoluteString))
        let secondPart = try XCTUnwrap(output.range(of: config.partialSegmentURL(for: partB).absoluteString))
        XCTAssertLessThan(firstMap.lowerBound, firstPart.lowerBound)
        XCTAssertLessThan(firstPart.lowerBound, secondMap.lowerBound)
        XCTAssertLessThan(secondMap.lowerBound, secondPart.lowerBound)
    }
}
