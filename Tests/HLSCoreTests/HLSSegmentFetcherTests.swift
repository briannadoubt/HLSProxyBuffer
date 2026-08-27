import CryptoKit
import os
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
        XCTAssertEqual(latest?.attemptCount, 1)
        XCTAssertEqual(latest?.retryCount, 0)
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

    func testCoalescesConcurrentRequestsAcrossRetrySequence() async throws {
        let expected = Data(repeating: 0xCD, count: 16)
        SegmentFetcherURLProtocol.enqueue(error: URLError(.networkConnectionLost))
        SegmentFetcherURLProtocol.enqueue(data: expected)
        let recorder = RetryDelayRecorder()
        let fetcher = makeFetcher(
            retryPolicy: .init(maxAttempts: 2, initialDelay: 1, jitterRatio: 0),
            retryClock: recorder.clock
        )

        let values = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/retry-shared.m4s")!)
                }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(values), [expected])
        XCTAssertEqual(SegmentFetcherURLProtocol.requestCount(), 2)
        XCTAssertEqual(recorder.delays, [1])
    }

    func testRetriesTransientErrorsWithExponentialBackoffAndJitter() async throws {
        SegmentFetcherURLProtocol.enqueue(error: URLError(.timedOut))
        SegmentFetcherURLProtocol.enqueue(error: URLError(.cannotConnectToHost))
        SegmentFetcherURLProtocol.enqueue(data: Data([0xA1]))
        let recorder = RetryDelayRecorder()
        let fetcher = makeFetcher(
            retryPolicy: .init(
                maxAttempts: 3,
                initialDelay: 2,
                multiplier: 2,
                maximumDelay: 10,
                jitterRatio: 0.25
            ),
            retryClock: recorder.clock,
            retryJitterSource: .init(nextValue: { 1 })
        )

        let data = try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/transient.ts")!)

        XCTAssertEqual(data, Data([0xA1]))
        XCTAssertEqual(recorder.delays, [2.5, 5])
        XCTAssertEqual(SegmentFetcherURLProtocol.requestCount(), 3)
        let metrics = await fetcher.latestMetrics()
        XCTAssertEqual(metrics?.attemptCount, 3)
        XCTAssertEqual(metrics?.retryCount, 2)
    }

    func testHonorsRetryAfterAndPreservesRangeAcrossAttempts() async throws {
        SegmentFetcherURLProtocol.enqueue(
            data: Data(),
            statusCode: 503,
            headers: ["Retry-After": "3"]
        )
        SegmentFetcherURLProtocol.enqueue(data: Data([10, 11, 12, 13]))
        let recorder = RetryDelayRecorder()
        let fetcher = makeFetcher(
            retryPolicy: .init(maxAttempts: 2, initialDelay: 0.25, jitterRatio: 0),
            retryClock: recorder.clock
        )

        let data = try await fetcher.fetchResource(
            at: URL(string: "https://cdn.example.com/ranged-retry.mp4")!,
            byteRange: 10...13
        )

        XCTAssertEqual(data, Data([10, 11, 12, 13]))
        XCTAssertEqual(recorder.delays, [3])
        XCTAssertEqual(
            SegmentFetcherURLProtocol.requests().map { $0.value(forHTTPHeaderField: "Range") },
            ["bytes=10-13", "bytes=10-13"]
        )
    }

    func testHonorsHTTPDateRetryAfterUsingInjectedClock() async throws {
        SegmentFetcherURLProtocol.enqueue(
            data: Data(),
            statusCode: 503,
            headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:03 GMT"]
        )
        SegmentFetcherURLProtocol.enqueue(data: Data([0x01]))
        let now = Date(timeIntervalSince1970: 1_445_412_480)
        let recorder = RetryDelayRecorder(now: now)
        let fetcher = makeFetcher(
            retryPolicy: .init(maxAttempts: 2, initialDelay: 0.25, jitterRatio: 0),
            retryClock: recorder.clock
        )

        _ = try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/date-retry.ts")!)

        XCTAssertEqual(recorder.delays, [3])
    }

    func testDoesNotRetryNonRetryableStatus() async {
        SegmentFetcherURLProtocol.enqueue(data: Data(), statusCode: 404)
        SegmentFetcherURLProtocol.enqueue(data: Data([0x01]))
        let recorder = RetryDelayRecorder()
        let fetcher = makeFetcher(
            retryPolicy: .init(maxAttempts: 3),
            retryClock: recorder.clock
        )

        do {
            _ = try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/missing.ts")!)
            XCTFail("Expected 404")
        } catch {
            guard case HLSSegmentFetcher.FetchError.httpStatus(404) = error else {
                return XCTFail("Expected 404, got \(error)")
            }
        }

        XCTAssertEqual(SegmentFetcherURLProtocol.requestCount(), 1)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    func testRetryClassificationIsExplicit() {
        let policy = HLSSegmentFetcher.RetryPolicy()

        XCTAssertTrue(policy.isRetryable(statusCode: 408))
        XCTAssertTrue(policy.isRetryable(statusCode: 429))
        XCTAssertTrue(policy.isRetryable(statusCode: 503))
        XCTAssertFalse(policy.isRetryable(statusCode: 404))
        XCTAssertTrue(policy.isRetryable(urlErrorCode: .networkConnectionLost))
        XCTAssertTrue(policy.isRetryable(urlErrorCode: .timedOut))
        XCTAssertFalse(policy.isRetryable(urlErrorCode: .cancelled))
        XCTAssertFalse(policy.isRetryable(urlErrorCode: .badURL))
    }

    func testRetriesChecksumMismatchAndValidatesSuccessfulAttempt() async throws {
        let expected = Data([0xBB])
        let digest = SHA256.hash(data: expected)
            .map { String(format: "%02hhx", $0) }
            .joined()
        SegmentFetcherURLProtocol.enqueue(data: Data([0xAA]))
        SegmentFetcherURLProtocol.enqueue(data: expected)
        let recorder = RetryDelayRecorder()
        let fetcher = makeFetcher(
            validation: .init(checksum: .init(algorithm: .sha256, value: digest)),
            retryPolicy: .init(maxAttempts: 2, initialDelay: 0, jitterRatio: 0),
            retryClock: recorder.clock
        )

        let data = try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/checksum-retry.ts")!)

        XCTAssertEqual(data, expected)
        XCTAssertEqual(SegmentFetcherURLProtocol.requestCount(), 2)
    }

    func testCancellationStopsBackoffAndPreventsAnotherAttempt() async {
        SegmentFetcherURLProtocol.enqueue(data: Data(), statusCode: 503)
        SegmentFetcherURLProtocol.enqueue(data: Data([0x01]))
        let clock = HLSSegmentFetcher.RetryClock(
            now: { Date() },
            sleep: { _ in try await Task.sleep(for: .seconds(30)) }
        )
        let fetcher = makeFetcher(
            retryPolicy: .init(maxAttempts: 3, initialDelay: 1),
            retryClock: clock
        )
        let task = Task {
            try await fetcher.fetchSegment(from: URL(string: "https://cdn.example.com/cancel.ts")!)
        }

        for _ in 0..<1_000 where SegmentFetcherURLProtocol.requestCount() == 0 {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(SegmentFetcherURLProtocol.requestCount(), 1)
    }

    func testCancellingOneCoalescedWaiterDoesNotCancelRemainingWaiter() async throws {
        let expected = Data([0xD1, 0xD2])
        SegmentFetcherURLProtocol.enqueue(data: expected)
        let fetcher = makeFetcher()
        let metricsStarted = expectation(description: "metrics started")
        await fetcher.onMetrics { _ in
            metricsStarted.fulfill()
            try? await Task.sleep(for: .milliseconds(50))
        }
        let url = URL(string: "https://cdn.example.com/shared-cancellation.ts")!
        let cancelledWaiter = Task { try await fetcher.fetchSegment(from: url) }
        let remainingWaiter = Task { try await fetcher.fetchSegment(from: url) }

        await fulfillment(of: [metricsStarted], timeout: 1)
        cancelledWaiter.cancel()

        let remainingData = try await remainingWaiter.value
        XCTAssertEqual(remainingData, expected)
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
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
        networkPolicy: HLSOriginNetworkPolicy = .default,
        retryPolicy: HLSSegmentFetcher.RetryPolicy = .init(maxAttempts: 1),
        retryClock: HLSSegmentFetcher.RetryClock = .continuous,
        retryJitterSource: HLSSegmentFetcher.RetryJitterSource = .init(nextValue: { 0 })
    ) -> HLSSegmentFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SegmentFetcherURLProtocol.self]
        let session = URLSession(configuration: config)
        return HLSSegmentFetcher(
            session: session,
            validationPolicy: validation,
            networkPolicy: networkPolicy,
            retryPolicy: retryPolicy,
            retryClock: retryClock,
            retryJitterSource: retryJitterSource
        )
    }
}

private final class RetryDelayRecorder: Sendable {
    private struct State: Sendable {
        var now: Date
        var delays: [TimeInterval] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    var clock: HLSSegmentFetcher.RetryClock {
        HLSSegmentFetcher.RetryClock(
            now: { [state] in state.withLock { $0.now } },
            sleep: { [state] delay in
                try Task.checkCancellation()
                state.withLock {
                    $0.delays.append(delay)
                    $0.now.addTimeInterval(delay)
                }
            }
        )
    }

    var delays: [TimeInterval] {
        state.withLock { $0.delays }
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
        guard let stub = Self.storage.nextStub() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")
        var headers = stub.headers
        if let range, headers["Content-Range"] == nil {
            headers["Content-Range"] = range.replacingOccurrences(of: "=", with: " ") + "/*"
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode ?? (range == nil ? 200 : 206),
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(
        data: Data,
        statusCode: Int? = nil,
        headers: [String: String] = [:]
    ) {
        storage.enqueue(.init(data: data, statusCode: statusCode, headers: headers, error: nil))
    }

    static func enqueue(error: URLError) {
        storage.enqueue(.init(data: Data(), statusCode: nil, headers: [:], error: error))
    }

    static func reset() {
        storage.reset()
    }

    static func lastRequest() -> URLRequest? { storage.lastRequest() }
    static func requests() -> [URLRequest] { storage.requests() }
    static func requestCount() -> Int { storage.requestCount() }

    private final class Storage: @unchecked Sendable {
        struct Stub {
            let data: Data
            let statusCode: Int?
            let headers: [String: String]
            let error: URLError?
        }

        private var queue: [Stub] = []
        private var recordedRequests: [URLRequest] = []
        private let lock = NSLock()

        func enqueue(_ stub: Stub) {
            lock.withLock {
                queue.append(stub)
            }
        }

        func nextStub() -> Stub? {
            lock.withLock {
                guard !queue.isEmpty else { return nil }
                return queue.removeFirst()
            }
        }

        func record(_ request: URLRequest) {
            lock.withLock {
                recordedRequests.append(request)
            }
        }

        func lastRequest() -> URLRequest? {
            lock.withLock { recordedRequests.last }
        }

        func requests() -> [URLRequest] {
            lock.withLock { recordedRequests }
        }

        func requestCount() -> Int {
            lock.withLock { recordedRequests.count }
        }

        func reset() {
            lock.withLock {
                queue.removeAll()
                recordedRequests.removeAll()
            }
        }
    }
}
