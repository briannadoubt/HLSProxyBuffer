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

    private func makeFetcher(
        validation: HLSSegmentFetcher.ValidationPolicy = .init()
    ) -> HLSSegmentFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SegmentFetcherURLProtocol.self]
        let session = URLSession(configuration: config)
        return HLSSegmentFetcher(session: session, validationPolicy: validation)
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
        guard let data = Self.storage.nextData() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
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

    private final class Storage: @unchecked Sendable {
        private var queue: [Data] = []
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

        func reset() {
            lock.withLock {
                queue.removeAll()
            }
        }
    }
}
