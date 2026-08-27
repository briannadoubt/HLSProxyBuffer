import XCTest
@testable import HLSCore

@MainActor
final class HLSSegmentFetcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SegmentFetcherURLProtocol.reset()
    }

    func testEnforcesByteRangeLength() async {
        SegmentFetcherURLProtocol.enqueue(data: Data([0x0, 0x1]))

        let fetcher = makeFetcher(validation: .init(enforceByteRangeLength: true))
        let segment = HLSSegment(
            url: URL(string: "https://cdn.example.com/short.ts")!,
            duration: 4,
            sequence: 1,
            byteRange: 0...3
        )

        do {
            _ = try await fetcher.fetchSegment(segment)
            XCTFail("Expected length mismatch")
        } catch {
            guard case HLSSegmentFetcher.FetchError.lengthMismatch = error else {
                return XCTFail("Expected length mismatch, got \(error)")
            }
        }
    }

    func testChecksumValidation() async {
        SegmentFetcherURLProtocol.enqueue(data: Data([0xAA]))
        let checksum = HLSSegmentFetcher.ValidationPolicy.Checksum(
            algorithm: .sha256,
            value: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        )
        let fetcher = makeFetcher(validation: .init(checksum: checksum))
        let segment = HLSSegment(
            url: URL(string: "https://cdn.example.com/checksum.ts")!,
            duration: 4,
            sequence: 1
        )

        do {
            _ = try await fetcher.fetchSegment(segment)
            XCTFail("Expected checksum mismatch")
        } catch {
            guard case HLSSegmentFetcher.FetchError.checksumMismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
    }

    func testMetricsCaptured() async throws {
        SegmentFetcherURLProtocol.enqueue(data: Data([0x0, 0x1, 0x2, 0x3]))
        let fetcher = makeFetcher()
        let expectation = expectation(description: "metrics")

        await fetcher.onMetrics { metrics in
            XCTAssertEqual(metrics.byteCount, 4)
            expectation.fulfill()
        }

        let data = try await fetcher.fetchSegment(
            HLSSegment(url: URL(string: "https://cdn.example.com/data.ts")!, duration: 4, sequence: 1)
        )
        XCTAssertEqual(data.count, 4)
        await fulfillment(of: [expectation], timeout: 1.0)
        let latest = await fetcher.latestMetrics()
        XCTAssertNotNil(latest)
    }

    func testSendsRangeHeaderAndValidatesContentRange() async throws {
        SegmentFetcherURLProtocol.enqueue(data: Data([10, 11, 12, 13]))
        let fetcher = makeFetcher()
        let segment = HLSSegment(
            url: URL(string: "https://cdn.example.com/media.mp4")!,
            duration: 4,
            sequence: 7,
            byteRange: 10...13
        )

        let data = try await fetcher.fetchSegment(segment)
        XCTAssertEqual(data, Data([10, 11, 12, 13]))
        XCTAssertEqual(SegmentFetcherURLProtocol.lastRequest()?.value(forHTTPHeaderField: "Range"), "bytes=10-13")
    }

    func testConcurrentRequestsForSameResourceAreCoalesced() async throws {
        let expected = Data(repeating: 0xAB, count: 32)
        SegmentFetcherURLProtocol.enqueue(data: expected)
        let fetcher = makeFetcher()
        await fetcher.onMetrics { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let segment = HLSSegment(
            url: URL(string: "https://cdn.example.com/shared.m4s")!,
            duration: 2,
            sequence: 9
        )

        let values = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0..<12 {
                group.addTask { try await fetcher.fetchSegment(segment) }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(values), [expected])
        XCTAssertEqual(SegmentFetcherURLProtocol.requestCount(), 1)
    }

    func testNetworkPolicySetsRequestTimeoutAndCanBeUpdated() async throws {
        SegmentFetcherURLProtocol.enqueue(data: Data([0x01]))
        SegmentFetcherURLProtocol.enqueue(data: Data([0x02]))
        let fetcher = makeFetcher(networkPolicy: .init(requestTimeout: 3, resourceTimeout: 30))

        _ = try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/first.ts")!)
        XCTAssertEqual(SegmentFetcherURLProtocol.lastRequest()?.timeoutInterval, 3)

        await fetcher.updateNetworkPolicy(.init(requestTimeout: 9, resourceTimeout: 30))
        _ = try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/second.ts")!)
        XCTAssertEqual(SegmentFetcherURLProtocol.lastRequest()?.timeoutInterval, 9)
    }

    private func makeFetcher(
        validation: HLSSegmentFetcher.ValidationPolicy = .init(),
        networkPolicy: HLSOriginNetworkPolicy = .default
    ) -> HLSSegmentFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SegmentFetcherURLProtocol.self]
        let session = URLSession(configuration: config)
        return HLSSegmentFetcher(
            session: session,
            validationPolicy: validation,
            networkPolicy: networkPolicy
        )
    }
}

private final class SegmentFetcherURLProtocol: URLProtocol {
    private static let storage = Storage()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.storage.record(request)
        guard let data = Self.storage.nextData() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: range == nil ? 200 : 206,
            httpVersion: nil,
            headerFields: range.map { ["Content-Range": $0.replacingOccurrences(of: "=", with: " ") + "/*"] }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(data: Data) {
        storage.enqueue(data)
    }

    static func reset() {
        storage.reset()
    }

    static func lastRequest() -> URLRequest? { storage.lastRequest() }
    static func requestCount() -> Int { storage.requestCount() }

    private final class Storage: @unchecked Sendable {
        private var queue: [Data] = []
        private var request: URLRequest?
        private var count = 0
        private let lock = NSLock()

        func enqueue(_ data: Data) {
            lock.withLock {
                queue.append(data)
            }
        }

        func nextData() -> Data? {
            lock.withLock {
                guard !queue.isEmpty else { return nil }
                return queue.removeFirst()
            }
        }

        func record(_ request: URLRequest) {
            lock.withLock {
                self.request = request
                count += 1
            }
        }

        func lastRequest() -> URLRequest? {
            lock.withLock { request }
        }

        func requestCount() -> Int {
            lock.withLock { count }
        }

        func reset() {
            lock.withLock {
                queue.removeAll()
                request = nil
                count = 0
            }
        }
    }
}
