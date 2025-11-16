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
}
