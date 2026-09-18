import XCTest
@testable import HLSCore

final class SegmentIdentityTests: XCTestCase {
    func testParsesPlainKey() {
        XCTAssertEqual(SegmentIdentity.sequence(from: "segment-42"), 42)
    }

    func testParsesKeyWithExtension() {
        XCTAssertEqual(SegmentIdentity.sequence(from: "segment-42.ts"), 42)
    }

    func testParsesKeyWithQueryParameters() {
        XCTAssertEqual(SegmentIdentity.sequence(from: "segment-42?foo=bar"), 42)
    }

    func testReturnsNilWhenDigitsMissing() {
        XCTAssertNil(SegmentIdentity.sequence(from: "segment-"))
    }

    func testHandlesNamespacedKeys() {
        let key = SegmentIdentity.key(forSequence: 7, namespace: "audio-main")
        XCTAssertEqual(key, "audio-main-segment-7")
        XCTAssertEqual(SegmentIdentity.sequence(from: key), 7)
        XCTAssertEqual(SegmentIdentity.namespace(from: key), "audio-main")
    }

    func testSanitizesNamespaceCharacters() {
        let key = SegmentIdentity.key(forSequence: 3, namespace: "Audio Main!?")
        XCTAssertEqual(key, "audio-main-segment-3")
    }

    func testPreservesExistingFingerprintKeys() throws {
        // Golden SHA-256 prefixes protect persisted cache and rewritten URL identity.
        let cases: [(String, ClosedRange<Int>?, String)] = [
            ("https://example.com/video.M4S?token=fixture", nil, "audio-main-segment-7-a6466231ced2b08191b3.m4s"),
            ("https://example.com/video.M4S?token=fixture", 0...99, "audio-main-segment-7-bacccf4ab013d5981fed.m4s"),
            ("https://example.com/video.M4S?token=fixture", 100...199, "audio-main-segment-7-4770bd534702e48a290c.m4s"),
            ("https://example.com/video.M4S?token=other", nil, "audio-main-segment-7-ae9baecb4386451b1cc2.m4s"),
        ]
        for (address, range, expected) in cases {
            let url = try XCTUnwrap(URL(string: address))
            let segment = HLSSegment(url: url, duration: 2, sequence: 7, byteRange: range)
            XCTAssertEqual(SegmentIdentity.key(for: segment, namespace: "Audio Main"), expected)
        }
    }
}
