import XCTest
@testable import HLSCore

final class PlaylistRefreshControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlaylistRefreshMockURLProtocol.reset()
    }

    func testDeliversUpdatesAndMetrics() async throws {
        PlaylistRefreshMockURLProtocol.enqueue(string: samplePlaylist(sequence: 0))
        PlaylistRefreshMockURLProtocol.enqueue(string: samplePlaylist(sequence: 2))

        let controller = makeController(interval: 0.05)
        let url = URL(string: "https://example.com/live.m3u8")!
        let expectation = expectation(description: "playlist refresh")
        expectation.expectedFulfillmentCount = 2
        var deliveredSequences: [Int] = []

        await controller.start(
            url: url,
            allowInsecure: false,
            retryPolicy: .init(maxAttempts: 1, retryDelay: 0),
            onUpdate: { playlist in
                await MainActor.run {
                    deliveredSequences.append(playlist.mediaSequence)
                    expectation.fulfill()
                }
            }
        )

        await fulfillment(of: [expectation], timeout: 2)
        await controller.stop()

        let metrics = await controller.metrics()
        XCTAssertNotNil(metrics.lastRefreshDate)
        XCTAssertEqual(metrics.remoteMediaSequence, deliveredSequences.last)
        XCTAssertEqual(metrics.consecutiveFailures, 0)
    }

    func testStopsAfterEndlist() async throws {
        PlaylistRefreshMockURLProtocol.enqueue(string: samplePlaylist(sequence: 5, endList: true))
        let controller = makeController(interval: 0.01)
        let url = URL(string: "https://example.com/vod.m3u8")!
        let expectation = expectation(description: "single refresh")

        await controller.start(
            url: url,
            allowInsecure: false,
            retryPolicy: .init(maxAttempts: 1, retryDelay: 0),
            onUpdate: { playlist in
                await MainActor.run {
                    XCTAssertTrue(playlist.isEndlist)
                    expectation.fulfill()
                }
            }
        )

        await fulfillment(of: [expectation], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(PlaylistRefreshMockURLProtocol.requestCount, 1)
        await controller.stop()
    }

    private func makeController(interval: TimeInterval) -> PlaylistRefreshController {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaylistRefreshMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return PlaylistRefreshController(
            configuration: .init(refreshInterval: interval, maxBackoffInterval: interval * 2),
            session: session,
            logger: TestLogger()
        )
    }

    private func samplePlaylist(sequence: Int, endList: Bool = false) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:\(sequence)"]
        lines.append(contentsOf: ["#EXTINF:3.0,", "segment-\(sequence).ts"])
        if endList {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n")
    }
}

private final class PlaylistRefreshMockURLProtocol: URLProtocol {
    struct Stub {
        let data: Data
        let response: URLResponse
        let error: Error?
    }

    private static let storage = Storage()

    static var requestCount: Int {
        storage.requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.storage.nextStub() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func enqueue(string: String, statusCode: Int = 200) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/live.m3u8")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        let stub = Stub(data: Data(string.utf8), response: response, error: nil)
        storage.enqueue(stub)
    }

    static func reset() {
        storage.reset()
    }

    private final class Storage: @unchecked Sendable {
        private var stubs: [Stub] = []
        private var internalRequestCount = 0
        private let lock = NSLock()

        var requestCount: Int {
            lock.withLock { internalRequestCount }
        }

        func enqueue(_ stub: Stub) {
            lock.withLock { stubs.append(stub) }
        }

        func nextStub() -> Stub? {
            lock.withLock {
                guard !stubs.isEmpty else { return nil }
                internalRequestCount += 1
                return stubs.removeFirst()
            }
        }

        func reset() {
            lock.withLock {
                stubs.removeAll()
                internalRequestCount = 0
            }
        }
    }
}

private struct TestLogger: Logger {
    func log(_ message: @autoclosure () -> String, category: LogCategory) {}
}
