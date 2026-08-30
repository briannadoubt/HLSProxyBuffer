import XCTest
@testable import LocalProxy

final class HTTPRequestTests: XCTestCase {
    func testHeadUsesRepresentationLengthWithoutAllocatingBody() {
        let response = HTTPResponse(status: .ok, representationLength: 42)
        XCTAssertTrue(response.body.isEmpty)
        let head = String(decoding: response.encoded(includeBody: false), as: UTF8.self)
        XCTAssertTrue(head.contains("Content-Length: 42\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
        let get = String(decoding: response.encoded(), as: UTF8.self)
        XCTAssertTrue(get.contains("Content-Length: 0\r\n"), "GET framing must match actual bytes")
    }

    func testNotModifiedOmitsUnknownLengthAndNeverEncodesBody() {
        let response = HTTPResponse(status: .notModified, body: Data("ignored".utf8))
        let encoded = String(decoding: response.encoded(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Content-Length:"))
        XCTAssertTrue(encoded.hasSuffix("\r\n\r\n"))
        let known = HTTPResponse(status: .notModified, representationLength: 42)
        XCTAssertTrue(String(decoding: known.headerData(), as: UTF8.self).contains("Content-Length: 42\r\n"))
    }

    func testResponseRemovesCaseInsensitiveConflictingLengthHeaders() {
        let response = HTTPResponse(
            status: .ok,
            headers: ["content-length": "999", "Content-Length": "888"],
            body: Data("actual".utf8)
        )
        let header = String(decoding: response.headerData(), as: UTF8.self)
        XCTAssertTrue(header.contains("Content-Length: 6\r\n"))
        XCTAssertFalse(header.contains("999"))
        XCTAssertFalse(header.contains("888"))
    }

    func testParserWaitsForFragmentedHeaders() throws {
        let firstFragment = Data("GET /playlist.m3u8 HTTP/1.1\r\nHost: localhost\r\n".utf8)
        XCTAssertNil(try HTTPRequestParser.parseAvailable(data: firstFragment))

        var complete = firstFragment
        complete.append(Data("Connection: keep-alive\r\n\r\n".utf8))
        let parsed = try XCTUnwrap(HTTPRequestParser.parseAvailable(data: complete))
        XCTAssertEqual(parsed.request.path, "/playlist.m3u8")
        XCTAssertTrue(parsed.request.shouldKeepAlive)
    }

    func testParserSeparatesLowLatencyQueryFromRoutePath() throws {
        let request = Data(
            "GET /playlist.m3u8?_HLS_msn=42&_HLS_part=3 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8
        )
        let parsed = try XCTUnwrap(HTTPRequestParser.parseAvailable(data: request))
        XCTAssertEqual(parsed.request.path, "/playlist.m3u8")
        XCTAssertEqual(parsed.request.queryItems["_HLS_msn"], "42")
        XCTAssertEqual(parsed.request.queryItems["_HLS_part"], "3")
    }

    func testParserRejectsOversizedRequests() {
        let oversized = Data(repeating: 0x41, count: HTTPRequestParser.maximumRequestBytes + 1)
        XCTAssertThrowsError(try HTTPRequestParser.parseAvailable(data: oversized))
    }

    func testParserRejectsAmbiguousBodyFraming() {
        let duplicateLength = Data(
            "POST /x HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8
        )
        let chunked = Data(
            "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
        )

        XCTAssertThrowsError(try HTTPRequestParser.parseAvailable(data: duplicateLength))
        XCTAssertThrowsError(try HTTPRequestParser.parseAvailable(data: chunked))
    }
}
