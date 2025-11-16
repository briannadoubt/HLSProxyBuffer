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
}
