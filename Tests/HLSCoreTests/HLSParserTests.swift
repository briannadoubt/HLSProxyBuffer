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
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
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
}
