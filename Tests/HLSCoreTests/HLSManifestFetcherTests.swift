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

    func testClientErrorDoesNotRetry() async {
        MockURLProtocol.enqueue(data: Data(), statusCode: 404)
        let fetcher = makeFetcher(retryPolicy: .init(maxAttempts: 4, retryDelay: 0))

        do {
            _ = try await fetcher.fetchManifest(from: URL(string: "https://example.com/missing.m3u8")!)
            XCTFail("Expected a client error")
        } catch {
            guard case HLSManifestFetcher.FetchError.httpStatus(404) = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testNetworkPolicySetsRequestTimeoutWithInjectedSession() async throws {
        MockURLProtocol.enqueue(data: "#EXTM3U".data(using: .utf8)!, statusCode: 200)
        let policy = HLSOriginNetworkPolicy(requestTimeout: 4.5, resourceTimeout: 30)
        let fetcher = makeFetcher(networkPolicy: policy)

        _ = try await fetcher.fetchManifest()

        XCTAssertEqual(MockURLProtocol.lastRequest?.timeoutInterval, 4.5)
        XCTAssertEqual(MockURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testConditionalFetchReturnsNotModifiedAndCapturesFreshness() async throws {
        MockURLProtocol.enqueue(
            data: Data(),
            statusCode: 304,
            headerFields: [
                "ETag": "\"manifest-v1\"",
                "Last-Modified": "Wed, 26 Aug 2026 00:00:00 GMT",
                "Cache-Control": "public, max-age=45",
            ]
        )
        let fetcher = makeFetcher()
        let url = URL(string: "https://example.com/master.m3u8")!

        let result = try await fetcher.fetchValidatedManifest(
            from: url,
            allowInsecure: false,
            ifNoneMatch: "\"manifest-v1\"",
            ifModifiedSince: "Wed, 26 Aug 2026 00:00:00 GMT"
        )

        guard case .notModified(let validation) = result else {
            return XCTFail("Expected a conditional 304 result")
        }
        XCTAssertEqual(validation.eTag, "\"manifest-v1\"")
        XCTAssertEqual(validation.lastModified, "Wed, 26 Aug 2026 00:00:00 GMT")
        XCTAssertEqual(validation.maximumAge, 45)
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "\"manifest-v1\"")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "If-Modified-Since"),
            "Wed, 26 Aug 2026 00:00:00 GMT"
        )
    }

    func testNoStoreAndNoCacheDirectivesDisablePersistenceAndForceRevalidation() async throws {
        MockURLProtocol.enqueue(
            data: Data("#EXTM3U".utf8),
            statusCode: 200,
            headerFields: ["Cache-Control": "private, no-cache, no-store"]
        )

        let result = try await makeFetcher().fetchValidatedManifest(
            from: URL(string: "https://example.com/master.m3u8")!,
            allowInsecure: false
        )

        guard case .modified(_, let validation) = result else {
            return XCTFail("Expected a modified manifest")
        }
        XCTAssertEqual(validation.maximumAge, 0)
        XCTAssertFalse(validation.allowsStorage)
    }

    private func makeFetcher(
        retryPolicy: HLSManifestFetcher.RetryPolicy = .default,
        networkPolicy: HLSOriginNetworkPolicy = .default
    ) -> HLSManifestFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HLSManifestFetcher(
            url: URL(string: "https://example.com/master.m3u8")!,
            session: session,
            retryPolicy: retryPolicy,
            networkPolicy: networkPolicy
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

    static var lastRequest: URLRequest? {
        storage.lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.storage.record(request)
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

    static func enqueue(
        data: Data,
        statusCode: Int,
        headerFields: [String: String]? = nil
    ) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/master.m3u8")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headerFields
        )!
        storage.enqueue(Stub(data: data, response: response, error: nil))
    }

    static func reset() {
        storage.reset()
    }

private final class Storage: @unchecked Sendable {
        private var stubs: [Stub] = []
        private var internalRequestCount = 0
        private var internalLastRequest: URLRequest?
        private let lock = NSLock()

        var requestCount: Int {
            lock.withLock { internalRequestCount }
        }

        var lastRequest: URLRequest? {
            lock.withLock { internalLastRequest }
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

        func record(_ request: URLRequest) {
            lock.withLock {
                internalRequestCount += 1
                internalLastRequest = request
            }
        }

        func reset() {
            lock.withLock {
                stubs.removeAll()
                internalRequestCount = 0
                internalLastRequest = nil
            }
        }
    }
}
