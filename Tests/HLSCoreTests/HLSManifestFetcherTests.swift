import XCTest
@testable import HLSCore

@MainActor
final class HLSManifestFetcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testSuccessfulFetchReturnsString() async throws {
        MockURLProtocol.enqueue(data: "#EXTM3U".data(using: .utf8)!, statusCode: 200)

        let fetcher = makeFetcher()
        let url = URL(string: "https://example.com/master.m3u8")!
        let manifest = try await fetcher.fetchManifest(from: url)
        XCTAssertEqual(manifest, "#EXTM3U")
    }

    func testRetriesOnFailureThenSucceeds() async throws {
        MockURLProtocol.enqueue(data: Data(), statusCode: 500)
        MockURLProtocol.enqueue(data: "#EXTM3U".data(using: .utf8)!, statusCode: 200)

        let fetcher = makeFetcher(retryPolicy: .init(maxAttempts: 2, retryDelay: 0))
        let url = URL(string: "https://example.com/master.m3u8")!
        let manifest = try await fetcher.fetchManifest(from: url)
        XCTAssertEqual(manifest, "#EXTM3U")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testInvalidUTF8Throws() async {
        MockURLProtocol.enqueue(data: Data([0xFF, 0xD9]), statusCode: 200)
        let fetcher = makeFetcher()
        let url = URL(string: "https://example.com/master.m3u8")!

        do {
            _ = try await fetcher.fetchManifest(from: url)
            XCTFail("Expected UTF-8 decoding error")
        } catch {
            guard case HLSManifestFetcher.FetchError.utf8Decoding = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    private func makeFetcher(
        retryPolicy: HLSManifestFetcher.RetryPolicy = .default
    ) -> HLSManifestFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HLSManifestFetcher(
            url: URL(string: "https://example.com/master.m3u8")!,
            session: session,
            retryPolicy: retryPolicy
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    struct Stub {
        let data: Data
        let response: URLResponse
        let error: Error?
    }

    private static let storage = Storage()

    static var requestCount: Int {
        storage.requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.storage.incrementRequestCount()
        guard let stub = Self.storage.nextStub() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
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

    static func enqueue(data: Data, statusCode: Int) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/master.m3u8")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        storage.enqueue(Stub(data: data, response: response, error: nil))
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
            lock.withLock {
                stubs.append(stub)
            }
        }

        func nextStub() -> Stub? {
            lock.withLock {
                guard !stubs.isEmpty else { return nil }
                return stubs.removeFirst()
            }
        }

        func incrementRequestCount() {
            lock.withLock {
                internalRequestCount += 1
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
