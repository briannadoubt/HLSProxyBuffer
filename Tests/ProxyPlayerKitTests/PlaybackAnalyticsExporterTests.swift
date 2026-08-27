import XCTest
@testable import ProxyPlayerKit

@MainActor
final class PlaybackAnalyticsExporterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AnalyticsExporterURLProtocol.reset()
    }

    func testDeterministicExportCodecMatchesGoldenJSONLinesAndRoundTrips() throws {
        let batch = try deterministicBatch()
        let data = try PlaybackAnalyticsExportCodec.encodeJSONLines(batch)

        XCTAssertEqual(data, try fixtureData(named: "analytics-export-batch-v1"))
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(
            try JSONDecoder().decode(PlaybackAnalyticsRecord.self, from: lines[0]),
            batch.records[0]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(PlaybackAnalyticsRecord.self, from: lines[1]),
            batch.records[1]
        )
    }

    func testInMemorySinkBoundsRecordsAndBatches() async throws {
        let sink = InMemoryPlaybackAnalyticsSink(configuration: .init(
            maximumRecordCount: 2,
            maximumBatchCount: 1
        ))
        let batch = try deterministicBatch()

        try await sink.send(batch)
        try await sink.send(.init(records: [batch.records[0]]))

        let snapshot = await sink.snapshot
        let records = await sink.records
        let batches = await sink.batches
        XCTAssertEqual(snapshot.acceptedRecordCount, 3)
        XCTAssertEqual(snapshot.acceptedBatchCount, 2)
        XCTAssertEqual(snapshot.evictedRecordCount, 1)
        XCTAssertEqual(snapshot.evictedBatchCount, 1)
        XCTAssertEqual(records, [batch.records[1], batch.records[0]])
        XCTAssertEqual(batches, [.init(records: [batch.records[0]])])
    }

    func testJSONLinesSinkRotatesWithinBoundAndPersistsOnlyTypedRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-exporter-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("analytics.jsonl")
        let sink = try JSONLinesPlaybackAnalyticsSink(
            fileURL: fileURL,
            configuration: .init(maximumFileBytes: 1_024, maximumArchiveCount: 1)
        )
        let batch = try deterministicBatch()

        try await sink.send(.init(records: [batch.records[0]]))
        try await sink.send(.init(records: [batch.records[1]]))

        let active = try Data(contentsOf: fileURL)
        let archived = try Data(contentsOf: URL(fileURLWithPath: fileURL.path + ".1"))
        XCTAssertEqual(
            active,
            try PlaybackAnalyticsExportCodec.encodeJSONLines(.init(records: [batch.records[1]]))
        )
        XCTAssertEqual(
            archived,
            try PlaybackAnalyticsExportCodec.encodeJSONLines(.init(records: [batch.records[0]]))
        )
        let combined = String(decoding: active + archived, as: UTF8.self)
        XCTAssertFalse(combined.contains("https://"))
        XCTAssertFalse(combined.localizedCaseInsensitiveContains("authorization"))
        let snapshot = await sink.snapshot
        XCTAssertEqual(snapshot.rotationCount, 1)
        XCTAssertLessThanOrEqual(snapshot.fileBytes, 1_024)
    }

    func testOSLogSinkAcceptsBatchWithoutEncodingPayloadText() async throws {
        let sink = OSLogPlaybackAnalyticsSink(
            subsystem: "com.example.HLSProxyBufferTests",
            category: "Exporter"
        )
        try await sink.send(try deterministicBatch())
    }

    func testHTTPSSinkUsesInjectedSessionEphemeralAuthorizationAndCanonicalBody() async throws {
        AnalyticsExporterURLProtocol.enqueue(statusCode: 202)
        let secret = "Bearer top-secret-credential"
        let configuration = try HTTPSPlaybackAnalyticsSink.Configuration(
            endpoint: URL(string: "https://analytics.example/v1/playback")!,
            compressionThresholdBytes: nil,
            authorization: .init { secret }
        )
        let sink = HTTPSPlaybackAnalyticsSink(
            session: makeSession(),
            configuration: configuration
        )
        let batch = try deterministicBatch()

        try await sink.send(batch)

        let request = try XCTUnwrap(AnalyticsExporterURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, configuration.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), secret)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Record-Count"), "2")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Encoding"))
        let body = try XCTUnwrap(AnalyticsExporterURLProtocol.lastBody)
        XCTAssertEqual(body, try PlaybackAnalyticsExportCodec.encode(batch))
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains(secret))
        XCTAssertTrue(bodyText.contains(batch.records[0].idempotencyID.encodedValue))
        XCTAssertTrue(bodyText.contains(batch.records[1].idempotencyID.encodedValue))
    }

    func testHTTPSSinkDeflatesCompressibleBoundedPayload() async throws {
        AnalyticsExporterURLProtocol.enqueue(statusCode: 200)
        let record = try deterministicBatch().records[0]
        let batch = PlaybackAnalyticsBatch(records: Array(repeating: record, count: 32))
        let raw = try PlaybackAnalyticsExportCodec.encode(batch)
        let sink = HTTPSPlaybackAnalyticsSink(
            session: makeSession(),
            configuration: try .init(
                endpoint: URL(string: "https://analytics.example/v1/playback")!,
                maximumPayloadBytes: 256 * 1_024,
                compressionThresholdBytes: 256
            )
        )

        try await sink.send(batch)

        let request = try XCTUnwrap(AnalyticsExporterURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "deflate")
        XCTAssertLessThan(try XCTUnwrap(AnalyticsExporterURLProtocol.lastBody).count, raw.count)
    }

    func testHTTPSSinkClassifiesEndpointTransportAndStatusFailures() async throws {
        XCTAssertThrowsError(try HTTPSPlaybackAnalyticsSink.Configuration(
            endpoint: URL(string: "http://analytics.example/v1/playback")!
        )) { error in
            XCTAssertEqual(
                error as? HTTPSPlaybackAnalyticsSink.Failure,
                .httpsEndpointRequired
            )
        }

        AnalyticsExporterURLProtocol.enqueue(
            statusCode: 302,
            headers: ["Location": "http://analytics.example/insecure"]
        )
        do {
            try await makeHTTPSSink().send(try deterministicBatch())
            XCTFail("Expected insecure redirect rejection")
        } catch let failure as HTTPSPlaybackAnalyticsSink.Failure {
            XCTAssertEqual(failure, .insecureRedirect)
            XCTAssertEqual(failure.retryDisposition, .permanent)
        }

        for (status, expected) in [
            (400, PlaybackAnalyticsRetryDisposition.permanent),
            (408, .retryable),
            (429, .retryable),
            (503, .retryable),
        ] {
            AnalyticsExporterURLProtocol.reset()
            AnalyticsExporterURLProtocol.enqueue(statusCode: status)
            let sink = try makeHTTPSSink()
            do {
                try await sink.send(try deterministicBatch())
                XCTFail("Expected HTTP \(status)")
            } catch let failure as HTTPSPlaybackAnalyticsSink.Failure {
                XCTAssertEqual(failure, .httpStatus(status))
                XCTAssertEqual(failure.retryDisposition, expected)
            }
        }

        AnalyticsExporterURLProtocol.reset()
        AnalyticsExporterURLProtocol.enqueue(error: URLError(.timedOut))
        do {
            try await makeHTTPSSink().send(try deterministicBatch())
            XCTFail("Expected transport failure")
        } catch let failure as HTTPSPlaybackAnalyticsSink.Failure {
            XCTAssertEqual(failure, .transport(.timedOut))
            XCTAssertEqual(failure.retryDisposition, .retryable)
        }
    }

    func testHTTPSSinkRejectsRecordPayloadAndAuthorizationBoundsBeforeNetwork() async throws {
        let batch = try deterministicBatch()
        let tooMany = HTTPSPlaybackAnalyticsSink(
            session: makeSession(),
            configuration: try .init(
                endpoint: URL(string: "https://analytics.example/v1/playback")!,
                maximumRecordCount: 1,
                compressionThresholdBytes: nil
            )
        )
        do {
            try await tooMany.send(batch)
            XCTFail("Expected record bound")
        } catch let failure as HTTPSPlaybackAnalyticsSink.Failure {
            XCTAssertEqual(failure, .tooManyRecords(limit: 1, actual: 2))
            XCTAssertEqual(failure.retryDisposition, .permanent)
        }
        XCTAssertNil(AnalyticsExporterURLProtocol.lastRequest)

        let tooLarge = HTTPSPlaybackAnalyticsSink(
            session: makeSession(),
            configuration: try .init(
                endpoint: URL(string: "https://analytics.example/v1/playback")!,
                maximumPayloadBytes: 1_024,
                maximumRecordCount: 4,
                compressionThresholdBytes: nil
            )
        )
        do {
            try await tooLarge.send(batch)
            XCTFail("Expected payload bound")
        } catch let failure as HTTPSPlaybackAnalyticsSink.Failure {
            guard case .payloadTooLarge(let limit, let actual) = failure else {
                return XCTFail("Unexpected failure \(failure)")
            }
            XCTAssertEqual(limit, 1_024)
            XCTAssertGreaterThan(actual, limit)
            XCTAssertEqual(failure.retryDisposition, .permanent)
        }
        XCTAssertNil(AnalyticsExporterURLProtocol.lastRequest)

        let invalidHeader = "Bearer secret"
            + String(UnicodeScalar(13))
            + String(UnicodeScalar(10))
            + "injected: value"
        XCTAssertTrue(invalidHeader.utf8.contains(13))
        XCTAssertTrue(invalidHeader.utf8.contains(10))

        let invalidAuthorization = HTTPSPlaybackAnalyticsSink(
            session: makeSession(),
            configuration: try .init(
                endpoint: URL(string: "https://analytics.example/v1/playback")!,
                compressionThresholdBytes: nil,
                authorization: .init { invalidHeader }
            )
        )
        do {
            try await invalidAuthorization.send(.init(records: [batch.records[0]]))
            XCTFail("Expected authorization bound")
        } catch let failure as HTTPSPlaybackAnalyticsSink.Failure {
            XCTAssertEqual(failure, .invalidAuthorization)
            XCTAssertEqual(failure.retryDisposition, .permanent)
        }
        XCTAssertNil(AnalyticsExporterURLProtocol.lastRequest)
    }

    func testDeliverySkipsRetriesForPermanentSinkFailure() async throws {
        let sink = PermanentFailureSink()
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                memoryBudgetBytes: 16 * 1_024,
                maximumQueuedRecordCount: 4,
                flushInterval: .seconds(60),
                retryPolicy: .init(
                    maximumAttempts: 4,
                    initialDelay: .milliseconds(1)
                )
            )
        )
        await delivery.record(try deterministicEvent())

        await delivery.flush()

        let sendCount = await sink.sendCount
        let snapshot = await delivery.snapshot
        XCTAssertEqual(sendCount, 1)
        XCTAssertEqual(snapshot.retryCount, 0)
        XCTAssertEqual(snapshot.exportFailureCount, 1)
        XCTAssertEqual(snapshot.queuedRecordCount, 0)
    }

    private func makeHTTPSSink() throws -> HTTPSPlaybackAnalyticsSink {
        HTTPSPlaybackAnalyticsSink(
            session: makeSession(),
            configuration: try .init(
                endpoint: URL(string: "https://analytics.example/v1/playback")!,
                compressionThresholdBytes: nil
            )
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnalyticsExporterURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private func deterministicBatch() throws -> PlaybackAnalyticsBatch {
        .init(records: [
            .event(try deterministicEvent()),
            .summary(try deterministicSummary()),
        ])
    }

    private func deterministicEvent() throws -> PlaybackAnalytics.Event {
        let catalog = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "media_kind": ["vod", "live", "stitched"],
        ])
        return try PlaybackAnalytics.Event(
            recordID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000004"
            )),
            correlation: try correlation(),
            timestamp: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                elapsedNanoseconds: 250_000_000
            ),
            source: .feedEngine,
            lifecycle: .playbackStarted,
            priority: .important,
            dimensions: try catalog.dimensions(from: [
                "cache_reuse": "warm",
                "media_kind": "vod",
            ]),
            measurements: [try .init(
                name: .init("first_frame_latency"),
                value: 187.5,
                unit: .milliseconds
            )]
        )
    }

    private func deterministicSummary() throws -> PlaybackAnalytics.Summary {
        let catalog = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "media_kind": ["vod", "live", "stitched"],
        ])
        return try PlaybackAnalytics.Summary(
            recordID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000005"
            )),
            correlation: try correlation(),
            startedAt: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                elapsedNanoseconds: 0
            ),
            endedAt: .init(
                anchor: .init(unixMilliseconds: 1_700_000_000_000),
                elapsedNanoseconds: 12_500_000_000
            ),
            terminalReason: .completed,
            dimensions: try catalog.dimensions(from: [
                "cache_reuse": "warm",
                "media_kind": "vod",
            ]),
            measurements: [
                try .init(name: .init("origin_bytes"), value: 1_024, unit: .bytes),
                try .init(name: .init("watch_duration"), value: 12.5, unit: .seconds),
            ]
        )
    }

    private func correlation() throws -> PlaybackAnalytics.Correlation {
        PlaybackAnalytics.Correlation(
            sessionID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000001"
            )),
            playbackID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000002"
            )),
            itemID: try XCTUnwrap(.init(
                encodedValue: "00000000-0000-4000-8000-000000000003"
            ))
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "jsonl",
            subdirectory: "Fixtures/Analytics"
        )))
    }
}

private actor PermanentFailureSink: PlaybackAnalyticsSink {
    enum Failure: Error, PlaybackAnalyticsRetryClassifyingError {
        case rejected

        var retryDisposition: PlaybackAnalyticsRetryDisposition { .permanent }
    }

    private(set) var sendCount = 0

    func send(_ batch: PlaybackAnalyticsBatch) async throws {
        sendCount += 1
        throw Failure.rejected
    }
}

private final class AnalyticsExporterURLProtocol: URLProtocol {
    struct Stub: @unchecked Sendable {
        let statusCode: Int?
        let headers: [String: String]
        let error: URLError?
    }

    private static let storage = Storage()

    static var lastRequest: URLRequest? { storage.lastRequest }
    static var lastBody: Data? { storage.lastBody }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.storage.record(request, body: Self.readBody(from: request))
        guard let stub = Self.storage.nextStub() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(
                stub.headers,
                uniquingKeysWith: { _, latest in latest }
            )
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func enqueue(statusCode: Int, headers: [String: String] = [:]) {
        storage.enqueue(.init(statusCode: statusCode, headers: headers, error: nil))
    }

    static func enqueue(error: URLError) {
        storage.enqueue(.init(statusCode: nil, headers: [:], error: error))
    }

    static func reset() {
        storage.reset()
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [Stub] = []
        private var request: URLRequest?
        private var body: Data?

        var lastRequest: URLRequest? {
            lock.withLock { request }
        }

        var lastBody: Data? {
            lock.withLock { body }
        }

        func enqueue(_ stub: Stub) {
            lock.withLock { stubs.append(stub) }
        }

        func nextStub() -> Stub? {
            lock.withLock {
                guard !stubs.isEmpty else { return nil }
                return stubs.removeFirst()
            }
        }

        func record(_ request: URLRequest, body: Data?) {
            lock.withLock {
                self.request = request
                self.body = body
            }
        }

        func reset() {
            lock.withLock {
                stubs.removeAll()
                request = nil
                body = nil
            }
        }
    }
}
