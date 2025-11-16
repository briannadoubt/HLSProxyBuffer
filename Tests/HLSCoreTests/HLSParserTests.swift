import XCTest
@testable import HLSCore

final class HLSParserTests: XCTestCase {
    func testParsesMediaPlaylist() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:1
        #EXTINF:4.000,
        segment1.ts
        #EXTINF:4.000,
        segment2.ts
        #EXT-X-ENDLIST
        """

        let parser = HLSParser()
        let baseURL = URL(string: "https://example.com/master.m3u8")!
        let manifest = try parser.parse(playlist, baseURL: baseURL)

        XCTAssertEqual(manifest.kind, .media)
        XCTAssertEqual(manifest.mediaPlaylist?.segments.count, 2)
        XCTAssertEqual(manifest.mediaPlaylist?.segments.first?.sequence, 1)
        XCTAssertEqual(
            manifest.mediaPlaylist?.segments.last?.url.absoluteString,
            "https://example.com/segment2.ts"
        )
    }

    func testParsesMasterVariants() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=750000,FRAME-RATE=29.97,RESOLUTION=640x360,CODECS="avc1.42e01e,mp4a.40.2"
        low/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,AVERAGE-BANDWIDTH=1300000,FRAME-RATE=59.94,RESOLUTION=1280x720,CODECS="avc1.4d001f,mp4a.40.2"
        high/prog_index.m3u8
        """

        let parser = HLSParser()
        let baseURL = URL(string: "https://cdn.example.com/master.m3u8")!
        let manifest = try parser.parse(master, baseURL: baseURL)

        XCTAssertEqual(manifest.kind, .master)
        XCTAssertEqual(manifest.variants.count, 2)
        XCTAssertEqual(
            manifest.variants.last?.url.absoluteString,
            "https://cdn.example.com/high/prog_index.m3u8"
        )

        let firstAttributes = manifest.variants.first?.attributes
        XCTAssertEqual(firstAttributes?.bandwidth, 800_000)
        XCTAssertEqual(firstAttributes?.averageBandwidth, 750_000)
        XCTAssertEqual(firstAttributes?.resolution, .init(width: 640, height: 360))
        XCTAssertEqual(firstAttributes?.codecs, "avc1.42e01e,mp4a.40.2")
        XCTAssertEqual(firstAttributes?.frameRate ?? 0, 29.97, accuracy: 0.01)
    }

    func testParsesLowLatencyPlaylist() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=6.0
        #EXT-X-PART-INF:PART-TARGET=1.0
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:3
        #EXTINF:4.000,
        s3.ts
        #EXTINF:4.000,
        s4.ts
        """

        let parser = HLSParser()
        let manifest = try parser.parse(playlist, baseURL: URL(string: "https://cdn.example.com/main.m3u8"))

        XCTAssertEqual(manifest.kind, .media)
        XCTAssertEqual(manifest.mediaPlaylist?.segments.count, 2)
        XCTAssertEqual(manifest.mediaPlaylist?.segments.first?.sequence, 3)
    }

    func testParsesAlternateRenditions() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/eng.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub-main",NAME="Spanish",LANGUAGE="es",AUTOSELECT=NO,FORCED=NO,URI="subs/spa.m3u8"
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc-main",NAME="CC1",LANGUAGE="en",INSTREAM-ID="CC1",DEFAULT=NO,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="audio-main",SUBTITLES="sub-main"
        variant/low.m3u8
        """

        let parser = HLSParser()
        let baseURL = URL(string: "https://cdn.example.com/master.m3u8")!
        let manifest = try parser.parse(playlist, baseURL: baseURL)

        XCTAssertEqual(manifest.kind, .master)
        XCTAssertEqual(manifest.renditions.count, 3)
        let audio = manifest.renditions.first { $0.type == .audio }
        XCTAssertEqual(audio?.groupId, "audio-main")
        XCTAssertEqual(audio?.isDefault, true)
        XCTAssertEqual(audio?.uri?.absoluteString, "https://cdn.example.com/audio/eng.m3u8")
        XCTAssertEqual(manifest.variants.first?.attributes.audioGroupId, "audio-main")
        XCTAssertEqual(manifest.variants.first?.attributes.subtitleGroupId, "sub-main")
        let captions = manifest.renditions.first { $0.type == .closedCaptions }
        XCTAssertEqual(captions?.instreamId, "CC1")
        XCTAssertNil(captions?.uri)
    }

    func testMissingRenditionURIThrows() {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="Broken"
        """

        let parser = HLSParser()
        XCTAssertThrowsError(try parser.parse(playlist, baseURL: nil)) { error in
            guard case HLSParser.ParserError.missingMediaAttribute(let attribute) = error else {
                XCTFail("Expected missing attribute error")
                return
            }
            XCTAssertEqual(attribute, "URI")
        }
    }

    func testClosedCaptionsRequireInstreamId() {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc-main",NAME="Broken CC"
        """

        let parser = HLSParser()
        XCTAssertThrowsError(try parser.parse(playlist, baseURL: nil)) { error in
            guard case HLSParser.ParserError.missingMediaAttribute(let attribute) = error else {
                XCTFail("Expected missing instream id error")
                return
            }
            XCTAssertEqual(attribute, "INSTREAM-ID")
        }
    }

    func testParsesAES128KeySegments() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/key.bin",IV=0x1234
        #EXTINF:4.0,
        segment1.ts
        """

        let parser = HLSParser()
        let manifest = try parser.parse(playlist, baseURL: URL(string: "https://cdn.example.com/master.m3u8"))

        let segment = try XCTUnwrap(manifest.mediaPlaylist?.segments.first)
        let encryption = try XCTUnwrap(segment.encryption)
        XCTAssertEqual(encryption.key.method, .aes128)
        XCTAssertEqual(encryption.key.uri?.absoluteString, "https://keys.example.com/key.bin")
        XCTAssertEqual(encryption.initializationVector, "0x1234")
    }

    func testParsesSampleAESKeyWithFormat() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset/123",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1/2"
        #EXTINF:4.0,
        segment1.ts
        """

        let parser = HLSParser()
        let manifest = try parser.parse(playlist, baseURL: URL(string: "https://cdn.example.com/video.m3u8"))

        let encryption = try XCTUnwrap(manifest.mediaPlaylist?.segments.first?.encryption)
        XCTAssertEqual(encryption.key.method, .sampleAES)
        XCTAssertEqual(encryption.key.keyFormat, "com.apple.streamingkeydelivery")
        XCTAssertEqual(encryption.key.keyFormatVersions, ["1", "2"])
    }

    func testMissingKeyMethodThrows() {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:URI="https://example.com/key.bin"
        #EXTINF:4.0,
        segment1.ts
        """

        let parser = HLSParser()
        XCTAssertThrowsError(try parser.parse(playlist, baseURL: nil)) { error in
            guard case HLSParser.ParserError.missingKeyAttribute(let attribute) = error else {
                XCTFail("Expected missing key attribute error")
                return
            }
            XCTAssertEqual(attribute, "METHOD")
        }
    }

    func testParsesSessionKeysAndInitializationMaps() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://session/abc",KEYFORMAT="com.apple"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE=720@0
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        segment1.ts
        """

        let parser = HLSParser()
        let baseURL = URL(string: "https://cdn.example.com/playlist.m3u8")!
        let manifest = try parser.parse(playlist, baseURL: baseURL)

        let sessionKey = try XCTUnwrap(manifest.mediaPlaylist?.sessionKeys.first)
        XCTAssertEqual(sessionKey.method, .sampleAES)
        XCTAssertEqual(sessionKey.uri?.absoluteString, "skd://session/abc")
        let segment = try XCTUnwrap(manifest.mediaPlaylist?.segments.first)
        let map = try XCTUnwrap(segment.initializationMap)
        XCTAssertEqual(map.uri.absoluteString, "https://cdn.example.com/init.mp4")
        XCTAssertEqual(map.byteRange, 0...719)
    }
}
