import Foundation
import XCTest
@testable import HLSCore

final class HLSClipStitcherTests: XCTestCase {
    private let parser = HLSParser()
    private let stitcher = HLSClipStitcher()

    func testCompatibleConformanceFixtureStitchesAndRewritesWithoutOriginLeak() throws {
        let main = try mediaPlaylist(
            named: "compatible-main",
            baseURL: URL(string: "https://main.media.example/path/playlist.m3u8")!
        )
        let insert = try mediaPlaylist(
            named: "compatible-insert",
            baseURL: URL(string: "https://insert.media.example/path/playlist.m3u8")!
        )

        let result = try stitcher.stitch([
            HLSClip(id: "main", playlist: main, mediaSignature: Self.avcFMP4Signature),
            HLSClip(id: "insert", playlist: insert, mediaSignature: Self.avcFMP4Signature),
        ])

        XCTAssertEqual(result.mediaSequence, 0)
        XCTAssertEqual(result.segments.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(result.discontinuitySequence, 0)
        XCTAssertEqual(result.playlistType, "VOD")
        XCTAssertTrue(result.isEndlist)
        XCTAssertTrue(result.independentSegments)
        XCTAssertEqual(result.targetDuration, 4)
        XCTAssertGreaterThanOrEqual(result.protocolVersion ?? 0, 6)
        XCTAssertEqual(result.segments.map(\.byteRange), [720...1_719, 1_720...2_719, nil, nil])
        XCTAssertEqual(result.segments[0].initializationMap?.byteRange, 0...719)
        XCTAssertEqual(result.segments[2].initializationMap?.byteRange, 0...639)
        XCTAssertEqual(
            result.segments[0].encryption?.initializationVector,
            "0x00000000000000000000000000000064"
        )
        XCTAssertEqual(
            result.segments[1].encryption?.initializationVector,
            "0x00000000000000000000000000000065"
        )
        XCTAssertEqual(
            result.segments[2].encryption?.initializationVector,
            "0x00000000000000000000000000000190"
        )
        XCTAssertFalse(result.segments[0].metadataTags.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertEqual(
            result.segments[2].metadataTags.filter { $0 == "#EXT-X-DISCONTINUITY" }.count,
            1
        )
        XCTAssertTrue(result.segments[0].metadataTags.contains {
            $0 == "#EXT-X-PROGRAM-DATE-TIME:2026-08-26T12:00:00.000Z"
        })
        XCTAssertTrue(result.segments[2].metadataTags.contains {
            $0 == "#EXT-X-PROGRAM-DATE-TIME:2026-08-26T12:00:08.000Z"
        })

        let proxyBaseURL = URL(string: "http://127.0.0.1:8123")!
        let rewritten = HLSRewriter().rewrite(
            mediaPlaylist: result,
            config: HLSRewriteConfiguration(
                proxyBaseURL: proxyBaseURL,
                keyURLResolver: { key in
                    guard let keyURL = key.uri else { return nil }
                    return proxyBaseURL
                        .appendingPathComponent("keys")
                        .appendingPathComponent(keyURL.lastPathComponent)
                }
            ),
            bufferState: BufferState(readySequences: Set(result.segments.map(\.sequence)))
        )

        XCTAssertFalse(rewritten.contains("media.example"))
        XCTAssertFalse(rewritten.contains("?token=one"))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:8123/segments/segment-0-"))
        XCTAssertTrue(rewritten.contains(".m4s"))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:8123/segments/map-"))
        XCTAssertTrue(rewritten.contains(".mp4"))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:8123/keys/main.key"))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:8123/keys/insert.key"))
    }

    func testConformanceRejectionsAreTyped() throws {
        let main = try mediaPlaylist(named: "compatible-main")
        let mismatch = try mediaPlaylist(named: "incompatible-codec")
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "main", playlist: main, mediaSignature: Self.avcFMP4Signature),
            HLSClip(id: "mismatch", playlist: mismatch, mediaSignature: Self.hevcFMP4Signature),
        ])) { error in
            XCTAssertEqual(error as? HLSClipStitchingError, .incompatibleMediaSignature(clipIndex: 1))
        }

        let live = try mediaPlaylist(named: "low-latency-live")
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "live", playlist: live, mediaSignature: Self.avcFMP4Signature),
        ])) { error in
            XCTAssertEqual(error as? HLSClipStitchingError, .unsupportedLiveOrLowLatencyPlaylist(clipIndex: 0))
        }

        let ad = try mediaPlaylist(named: "ad-interstitial")
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "ad", playlist: ad, mediaSignature: Self.avcFMP4Signature),
        ])) { error in
            guard case .interstitialMetadataRequiresInterstitialPath(clipIndex: 0, let tag) =
                error as? HLSClipStitchingError
            else {
                return XCTFail("Expected typed interstitial rejection, got \(error)")
            }
            XCTAssertTrue(tag.hasPrefix("#EXT-X-DATERANGE:"))
        }

        let overlap = try mediaPlaylist(named: "overlapping-program-date-time")
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "main", playlist: main, mediaSignature: Self.avcFMP4Signature),
            HLSClip(id: "overlap", playlist: overlap, mediaSignature: Self.avcFMP4Signature),
        ])) { error in
            XCTAssertEqual(
                error as? HLSClipStitchingError,
                .ambiguousProgramDateTime(clipIndex: 1, segmentIndex: 0)
            )
        }
    }

    func testRejectsInvalidDurationsNonIndependentVideoAndEncryptedMapWithoutIV() throws {
        let url = URL(string: "https://media.example/segment.m4s")!
        let mapURL = URL(string: "https://media.example/init.mp4")!
        let key = HLSKey(
            method: .aes128,
            uri: URL(string: "https://media.example/key")
        )
        let valid = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 7,
            segments: [HLSSegment(
                url: url,
                duration: 4,
                sequence: 7,
                initializationMap: MediaInitializationMap(uri: mapURL)
            )],
            isEndlist: true,
            independentSegments: true,
            playlistType: "VOD"
        )

        let invalidDuration = replacingFirstSegment(
            in: valid,
            with: HLSSegment(
                url: url,
                duration: .nan,
                sequence: 7,
                initializationMap: MediaInitializationMap(uri: mapURL)
            )
        )
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "invalid", playlist: invalidDuration, mediaSignature: Self.avcFMP4Signature),
        ])) { error in
            XCTAssertEqual(
                error as? HLSClipStitchingError,
                .invalidSegmentDuration(clipIndex: 0, segmentIndex: 0)
            )
        }

        let nonIndependent = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 7,
            segments: valid.segments,
            isEndlist: true,
            independentSegments: false,
            playlistType: "VOD"
        )
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "video", playlist: nonIndependent, mediaSignature: Self.avcFMP4Signature),
        ])) { error in
            XCTAssertEqual(error as? HLSClipStitchingError, .videoRequiresIndependentSegments(clipIndex: 0))
        }

        let invalidMap = replacingFirstSegment(
            in: valid,
            with: HLSSegment(
                url: url,
                duration: 4,
                sequence: 7,
                initializationMap: MediaInitializationMap(
                    uri: mapURL,
                    encryption: SegmentEncryption(key: key)
                )
            )
        )
        XCTAssertThrowsError(try stitcher.stitch([
            HLSClip(id: "encrypted-map", playlist: invalidMap, mediaSignature: Self.avcFMP4Signature),
        ])) { error in
            XCTAssertEqual(
                error as? HLSClipStitchingError,
                .encryptedInitializationMapRequiresExplicitIV(clipIndex: 0, segmentIndex: 0)
            )
        }
    }

    func testParserCapturesMapEncryptionAndRewriterKeepsMapAndSegmentKeyScopes() throws {
        let source = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:8
        #EXT-X-KEY:METHOD=AES-128,URI="map.key",IV=0x00000000000000000000000000000008
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="media.key",IV=0x00000000000000000000000000000009
        #EXT-X-PROGRAM-DATE-TIME:2026-08-26T12:00:00Z
        #EXTINF:4,
        media.m4s
        #EXT-X-ENDLIST
        """
        let manifest = try parser.parse(
            source,
            baseURL: URL(string: "https://origin.example/playlist.m3u8")!
        )
        let playlist = try XCTUnwrap(manifest.mediaPlaylist)
        XCTAssertEqual(playlist.segments[0].initializationMap?.encryption?.key.uri?.lastPathComponent, "map.key")
        XCTAssertEqual(playlist.segments[0].encryption?.key.uri?.lastPathComponent, "media.key")

        let proxyBaseURL = URL(string: "http://127.0.0.1:8090")!
        let rewritten = HLSRewriter().rewrite(
            mediaPlaylist: playlist,
            config: HLSRewriteConfiguration(
                proxyBaseURL: proxyBaseURL,
                keyURLResolver: { key in
                    key.uri.map { proxyBaseURL.appendingPathComponent("keys/\($0.lastPathComponent)") }
                }
            ),
            bufferState: BufferState(readySequences: [8])
        )
        let mapKey = try XCTUnwrap(rewritten.range(of: "/keys/map.key"))
        let map = try XCTUnwrap(rewritten.range(of: "#EXT-X-MAP:"))
        let segmentKey = try XCTUnwrap(rewritten.range(of: "/keys/media.key"))
        let segmentMetadata = try XCTUnwrap(rewritten.range(of: "#EXT-X-PROGRAM-DATE-TIME:"))
        let segment = try XCTUnwrap(rewritten.range(of: "/segments/segment-8-"))
        XCTAssertLessThan(mapKey.lowerBound, map.lowerBound)
        XCTAssertLessThan(map.lowerBound, segmentKey.lowerBound)
        XCTAssertLessThan(segmentKey.lowerBound, segmentMetadata.lowerBound)
        XCTAssertLessThan(segmentMetadata.lowerBound, segment.lowerBound)
    }

    func testResourceIdentityPreservesSanitizedExtensionsAndFingerprintUniqueness() {
        let first = HLSSegment(
            url: URL(string: "https://one.example/shared/video.M4S?token=secret")!,
            duration: 1,
            sequence: 0,
            byteRange: 0...99
        )
        let second = HLSSegment(
            url: URL(string: "https://two.example/shared/video.M4S?token=secret")!,
            duration: 1,
            sequence: 0,
            byteRange: 0...99
        )
        let fallback = MediaInitializationMap(uri: URL(string: "https://one.example/init")!)

        XCTAssertTrue(SegmentIdentity.key(for: first).hasSuffix(".m4s"))
        XCTAssertNotEqual(SegmentIdentity.key(for: first), SegmentIdentity.key(for: second))
        XCTAssertTrue(SegmentIdentity.key(for: fallback).hasSuffix(".bin"))
    }

    private func replacingFirstSegment(in playlist: MediaPlaylist, with segment: HLSSegment) -> MediaPlaylist {
        MediaPlaylist(
            protocolVersion: playlist.protocolVersion,
            targetDuration: playlist.targetDuration,
            mediaSequence: playlist.mediaSequence,
            segments: [segment],
            isEndlist: playlist.isEndlist,
            sessionKeys: playlist.sessionKeys,
            independentSegments: playlist.independentSegments,
            playlistType: playlist.playlistType,
            discontinuitySequence: playlist.discontinuitySequence
        )
    }

    private func mediaPlaylist(
        named name: String,
        baseURL: URL = URL(string: "https://media.example/path/playlist.m3u8")!
    ) throws -> MediaPlaylist {
        let text = try String(
            contentsOf: fixtureURL(name, extension: "m3u8"),
            encoding: .utf8
        )
        return try XCTUnwrap(parser.parse(text, baseURL: baseURL).mediaPlaylist)
    }

    private func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures/ClipStitching"
        ))
    }

    private static let avcFMP4Signature = HLSClipMediaSignature(
        container: .fragmentedMP4,
        codecs: ["avc1.640028", "mp4a.40.2"],
        tracks: [
            .init(kind: .video, codec: "avc1.640028"),
            .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
        ],
        videoRange: "SDR",
        segmentsAreIndependent: true
    )

    private static let hevcFMP4Signature = HLSClipMediaSignature(
        container: .fragmentedMP4,
        codecs: ["hvc1.2.4.L123.B0", "mp4a.40.2"],
        tracks: [
            .init(kind: .video, codec: "hvc1.2.4.L123.B0"),
            .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
        ],
        videoRange: "SDR",
        segmentsAreIndependent: true
    )
}
