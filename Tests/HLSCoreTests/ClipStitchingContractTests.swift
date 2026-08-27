import XCTest
@testable import HLSCore

final class ClipStitchingContractTests: XCTestCase {
    private let parser = HLSParser()
    private let baseURL = URL(string: "https://media.example.com/path/playlist.m3u8")!

    func testExpectationIndexIsValidAndCoversAllDecisions() throws {
        let data = try Data(contentsOf: fixtureURL("expectations", extension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        XCTAssertEqual(
            Set(cases.compactMap { $0["result"] as? String }),
            [
                "success",
                "incompatibleMediaSignature",
                "unsupportedLiveOrLowLatencyPlaylist",
                "interstitialMetadataRequiresInterstitialPath",
                "ambiguousProgramDateTime"
            ]
        )
    }

    func testCompatibleFixturesCarrySequenceMapKeyRangeAndDateState() throws {
        let main = try mediaPlaylist(named: "compatible-main")
        XCTAssertTrue(main.isEndlist)
        XCTAssertEqual(main.playlistType, "VOD")
        XCTAssertTrue(main.independentSegments)
        XCTAssertEqual(main.mediaSequence, 100)
        XCTAssertEqual(main.segments.map(\.sequence), [100, 101])
        XCTAssertEqual(main.segments.first?.initializationMap?.byteRange, 0...719)
        XCTAssertEqual(main.segments.map(\.byteRange), [720...1_719, 1_720...2_719])
        XCTAssertEqual(main.segments.first?.encryption?.key.method, .aes128)
        XCTAssertNil(main.segments.first?.encryption?.initializationVector)
        XCTAssertTrue(main.segments.first?.metadataTags.contains {
            $0.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:")
        } ?? false)

        let insert = try mediaPlaylist(named: "compatible-insert")
        XCTAssertEqual(insert.mediaSequence, 400)
        XCTAssertEqual(insert.segments.map(\.sequence), [400, 401])
        XCTAssertEqual(
            insert.segments.first?.encryption?.initializationVector,
            "0x00000000000000000000000000000190"
        )
    }

    func testRejectionFixturesCarryTheStateNamedByTheContract() throws {
        let live = try mediaPlaylist(named: "low-latency-live")
        XCTAssertFalse(live.isEndlist)
        XCTAssertNotNil(live.serverControl)
        XCTAssertNotNil(live.partTargetDuration)
        XCTAssertFalse(live.segments.flatMap(\.parts).isEmpty)
        XCTAssertFalse(live.preloadHints.isEmpty)

        let ad = try mediaPlaylist(named: "ad-interstitial")
        XCTAssertTrue(ad.segments.first?.metadataTags.contains {
            $0.hasPrefix("#EXT-X-DATERANGE:")
        } ?? false)

        let overlap = try mediaPlaylist(named: "overlapping-program-date-time")
        XCTAssertTrue(overlap.segments.first?.metadataTags.contains {
            $0.contains("2026-08-26T12:00:04.000Z")
        } ?? false)
    }

    private func mediaPlaylist(named name: String) throws -> MediaPlaylist {
        let text = try String(
            contentsOf: fixtureURL(name, extension: "m3u8"),
            encoding: .utf8
        )
        let manifest = try parser.parse(text, baseURL: baseURL)
        XCTAssertEqual(manifest.kind, .media)
        return try XCTUnwrap(manifest.mediaPlaylist)
    }

    private func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures/ClipStitching"
        ))
    }
}
