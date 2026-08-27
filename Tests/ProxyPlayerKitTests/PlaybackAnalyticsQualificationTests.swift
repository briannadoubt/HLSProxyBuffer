import Foundation
@testable import ProxyPlayerKit
import XCTest

@MainActor
final class PlaybackAnalyticsQualificationTests: XCTestCase {
    private static let eventCount = 100_000

    private struct ScaleReport: Codable {
        let configuration: String
        let eventCount: Int
        let timelineEmittedEventCount: UInt64
        let timelineDroppedEventCount: UInt64
        let timelineEventBufferLimit: Int
        let summaryStallCount: Double
        let summaryStallDurationSeconds: Double
        let telemetryDroppedEventCount: UInt64
        let telemetrySubscriberLimit: Int
        let telemetryBufferLimitPerSubscriber: Int
        let telemetryMaximumBufferedEventCount: Int
        let telemetryRejectedSubscriberCount: UInt64
        let deliveryMaximumQueuedRecordCount: Int
        let deliveryQueuedRecordLimit: Int
        let deliveryMaximumQueuedBytes: Int
        let deliveryMemoryLimitBytes: Int
        let deliveryMaximumTaskCount: Int
        let deliveryTaskLimit: Int
        let deliveredRecordCount: UInt64
        let droppedRecordCount: UInt64
        let summaryDelivered: Bool
    }

    private struct RecoveryReport: Codable {
        let configuration: String
        let admittedRecordCount: Int
        let offlineExportFailureCount: UInt64
        let offlineSpooledRecordCount: Int
        let offlineSpoolRecordLimit: Int
        let offlineSpooledBytes: Int
        let offlineSpoolByteLimit: Int
        let recoveredDeliveredRecordCount: UInt64
        let recoveredDroppedRecordCount: UInt64
        let finalQueuedRecordCount: Int
        let finalSpooledRecordCount: Int
        let finalActiveTaskCount: Int
        let maximumTaskCount: Int
        let taskLimit: Int
    }

    private struct PrivacyReport: Codable {
        let configuration: String
        let encodedRecordCount: Int
        let scannedPayloadBytes: Int
        let scannedSpoolBytes: Int
        let forbiddenPatternCount: Int
        let opaqueIdentifierCount: Int
    }

    func testOneHundredThousandEventsStayBoundedAndSummariesReconcileExactly() async throws {
        let eventBufferLimit = 32
        let telemetryBufferLimit = 8
        let telemetrySubscriberLimit = 2
        let deliveryRecordLimit = 64
        let deliveryMemoryLimit = 32 * 1_024
        let telemetry = HLSFeedTelemetry(configuration: .init(
            latencyUpperBounds: [0.001, 0.01],
            eventBufferCapacity: telemetryBufferLimit,
            maximumSubscriberCount: telemetrySubscriberLimit
        ))
        let firstTelemetryStream = telemetry.events()
        let secondTelemetryStream = telemetry.events()
        let rejectedTelemetryStream = telemetry.events()
        let timeline = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: eventBufferLimit,
            summaryBufferCapacity: 4,
            maximumActiveAttemptCount: 4
        ))
        let attempt = timeline.beginAttempt(attribution: .init(
            reuse: .warm,
            intent: .focused,
            mediaKind: .videoOnDemand
        ))
        let stallCount = try PlaybackAnalytics.Measurement(
            name: .init("stall_count"),
            value: 1,
            unit: .count
        )
        let stallDuration = try PlaybackAnalytics.Measurement(
            name: .init("stall_duration"),
            value: 0.001,
            unit: .seconds
        )
        let deliveryClock = PlaybackAnalytics.TimelineClock()
        let sink = QualificationSwitchableSink(mode: .blocked)
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                memoryBudgetBytes: deliveryMemoryLimit,
                maximumQueuedRecordCount: deliveryRecordLimit,
                maximumBatchBytes: 8 * 1_024,
                maximumBatchRecordCount: 8,
                flushInterval: .zero,
                shutdownFlushTimeout: .seconds(1),
                retryPolicy: .init(maximumAttempts: 1)
            )
        )

        for index in 0..<Self.eventCount {
            telemetry.record(.init(
                path: .init(reuse: .warm, intent: .focused, mediaKind: .videoOnDemand),
                payload: .stall(duration: 0.001)
            ))
            timeline.record(
                source: .feedEngine,
                lifecycle: .stalled,
                measurements: [stallCount, stallDuration],
                attempt: attempt
            )
            await delivery.record(try makeEvent(
                correlation: attempt.correlation,
                clock: deliveryClock,
                lifecycle: .stalled,
                priority: .routine,
                measurements: [stallCount, stallDuration]
            ))
            if index == 0 {
                try await waitUntil { await sink.attemptCount == 1 }
            }
        }
        timeline.end(attempt, reason: .completed)
        timeline.finish()
        let summaries = await collect(timeline.summaries)
        let summary = try XCTUnwrap(summaries.only)
        await delivery.record(summary)

        let boundedDelivery = await delivery.snapshot
        XCTAssertLessThanOrEqual(
            boundedDelivery.maximumObservedQueuedRecordCount,
            deliveryRecordLimit
        )
        XCTAssertLessThanOrEqual(
            boundedDelivery.maximumObservedQueuedBytes,
            deliveryMemoryLimit
        )
        XCTAssertLessThanOrEqual(
            boundedDelivery.maximumObservedTaskCount,
            boundedDelivery.taskLimit
        )
        XCTAssertEqual(boundedDelivery.droppedCriticalRecordCount, 0)
        XCTAssertGreaterThan(boundedDelivery.droppedRoutineRecordCount, 0)

        await sink.setMode(.online)
        await delivery.flush()
        let didShutdownCleanly = await delivery.shutdown()
        XCTAssertTrue(didShutdownCleanly)
        let deliveredRecords = await sink.deliveredRecords
        let finalDelivery = await delivery.snapshot
        let droppedRecordCount = Self.droppedRecordCount(finalDelivery)
        XCTAssertTrue(deliveredRecords.contains(.summary(summary)))
        XCTAssertEqual(
            Set(deliveredRecords.map(\.idempotencyID)).count,
            deliveredRecords.count
        )
        XCTAssertEqual(
            finalDelivery.deliveredRecordCount + droppedRecordCount,
            UInt64(Self.eventCount + 1)
        )
        XCTAssertEqual(finalDelivery.activeTaskCount, 0)

        let summaryValues = Dictionary(uniqueKeysWithValues: summary.measurements.map {
            ($0.name.encodedValue, $0.value)
        })
        XCTAssertEqual(summaryValues["stall_count"], Double(Self.eventCount))
        XCTAssertEqual(
            try XCTUnwrap(summaryValues["stall_duration"]),
            Double(Self.eventCount) * 0.001,
            accuracy: 0.000_001
        )
        XCTAssertEqual(timeline.snapshot.activeAttemptCount, 0)
        XCTAssertEqual(timeline.snapshot.emittedEventCount, UInt64(Self.eventCount + 2))
        XCTAssertEqual(
            timeline.snapshot.droppedEventCount,
            UInt64(Self.eventCount + 2 - eventBufferLimit)
        )
        XCTAssertEqual(timeline.snapshot.emittedSummaryCount, 1)
        XCTAssertEqual(timeline.snapshot.droppedSummaryCount, 0)

        let rejectedTelemetryEvents = await collect(rejectedTelemetryStream)
        XCTAssertTrue(rejectedTelemetryEvents.isEmpty)
        let telemetryBeforeFinish = telemetry.snapshot
        XCTAssertEqual(telemetryBeforeFinish.eventCount, UInt64(Self.eventCount))
        XCTAssertEqual(telemetryBeforeFinish.activeSubscriberCount, telemetrySubscriberLimit)
        XCTAssertEqual(telemetryBeforeFinish.rejectedSubscriberCount, 1)
        XCTAssertEqual(
            telemetryBeforeFinish.droppedEventCount,
            UInt64((Self.eventCount - telemetryBufferLimit) * telemetrySubscriberLimit)
        )
        telemetry.finish()
        let firstTelemetryCount = await collect(firstTelemetryStream).count
        let secondTelemetryCount = await collect(secondTelemetryStream).count
        XCTAssertEqual(firstTelemetryCount, telemetryBufferLimit)
        XCTAssertEqual(secondTelemetryCount, telemetryBufferLimit)
        XCTAssertEqual(telemetry.snapshot.activeSubscriberCount, 0)

        try QualificationArtifact.write(
            ScaleReport(
                configuration: artifactConfiguration,
                eventCount: Self.eventCount,
                timelineEmittedEventCount: timeline.snapshot.emittedEventCount,
                timelineDroppedEventCount: timeline.snapshot.droppedEventCount,
                timelineEventBufferLimit: eventBufferLimit,
                summaryStallCount: try XCTUnwrap(summaryValues["stall_count"]),
                summaryStallDurationSeconds: try XCTUnwrap(
                    summaryValues["stall_duration"]
                ),
                telemetryDroppedEventCount: telemetryBeforeFinish.droppedEventCount,
                telemetrySubscriberLimit: telemetrySubscriberLimit,
                telemetryBufferLimitPerSubscriber: telemetryBufferLimit,
                telemetryMaximumBufferedEventCount: telemetryBeforeFinish
                    .storageBound.maximumBufferedEventCount,
                telemetryRejectedSubscriberCount: telemetryBeforeFinish
                    .rejectedSubscriberCount,
                deliveryMaximumQueuedRecordCount: boundedDelivery
                    .maximumObservedQueuedRecordCount,
                deliveryQueuedRecordLimit: deliveryRecordLimit,
                deliveryMaximumQueuedBytes: boundedDelivery.maximumObservedQueuedBytes,
                deliveryMemoryLimitBytes: deliveryMemoryLimit,
                deliveryMaximumTaskCount: finalDelivery.maximumObservedTaskCount,
                deliveryTaskLimit: finalDelivery.taskLimit,
                deliveredRecordCount: finalDelivery.deliveredRecordCount,
                droppedRecordCount: droppedRecordCount,
                summaryDelivered: deliveredRecords.contains(.summary(summary))
            ),
            named: artifactName("hls-playback-analytics-scale")
        )
    }

    func testOfflineExporterShedsWithinDiskBoundsRecoversAndReleasesTasks() async throws {
        let spoolRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PlaybackAnalyticsQualification-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: spoolRoot) }
        let sink = QualificationSwitchableSink(mode: .offline)
        let spoolRecordLimit = 32
        let spoolByteLimit = 32 * 1_024
        let admittedRecordCount = 101
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                memoryBudgetBytes: 32 * 1_024,
                maximumQueuedRecordCount: 64,
                maximumBatchBytes: 8 * 1_024,
                maximumBatchRecordCount: 16,
                flushInterval: .seconds(999),
                shutdownFlushTimeout: .seconds(1),
                retryPolicy: .init(maximumAttempts: 1),
                diskSpool: .init(
                    directory: spoolRoot,
                    maximumBytes: spoolByteLimit,
                    maximumRecordCount: spoolRecordLimit
                )
            )
        )
        let correlation = PlaybackAnalytics.Correlation(
            sessionID: .init(),
            playbackID: .init(),
            itemID: .init()
        )
        let event = try makeEvent(correlation: correlation)
        for _ in 0..<100 {
            await delivery.record(try makeEvent(correlation: correlation))
        }
        let summary = try makeSummary(correlation: correlation)
        await delivery.record(summary)
        await delivery.flush()

        let offline = await delivery.snapshot
        XCTAssertGreaterThan(offline.exportFailureCount, 0)
        XCTAssertGreaterThan(offline.spooledRecordCount, 0)
        XCTAssertLessThanOrEqual(offline.spooledRecordCount, spoolRecordLimit)
        XCTAssertLessThanOrEqual(offline.spooledBytes, spoolByteLimit)
        XCTAssertEqual(offline.droppedCriticalRecordCount, 0)

        await sink.setMode(.online)
        await delivery.flush()
        let didShutdownCleanly = await delivery.shutdown()
        XCTAssertTrue(didShutdownCleanly)
        let recovered = await delivery.snapshot
        let dropped = Self.droppedRecordCount(recovered)
        XCTAssertEqual(recovered.queuedRecordCount, 0)
        XCTAssertEqual(recovered.spooledRecordCount, 0)
        XCTAssertEqual(recovered.activeTaskCount, 0)
        XCTAssertLessThanOrEqual(recovered.maximumObservedTaskCount, recovered.taskLimit)
        XCTAssertEqual(
            recovered.deliveredRecordCount + dropped,
            UInt64(admittedRecordCount)
        )
        let recoveredRecords = await sink.deliveredRecords
        XCTAssertTrue(recoveredRecords.contains(.summary(summary)))

        try QualificationArtifact.write(
            RecoveryReport(
                configuration: artifactConfiguration,
                admittedRecordCount: admittedRecordCount,
                offlineExportFailureCount: offline.exportFailureCount,
                offlineSpooledRecordCount: offline.spooledRecordCount,
                offlineSpoolRecordLimit: spoolRecordLimit,
                offlineSpooledBytes: offline.spooledBytes,
                offlineSpoolByteLimit: spoolByteLimit,
                recoveredDeliveredRecordCount: recovered.deliveredRecordCount,
                recoveredDroppedRecordCount: dropped,
                finalQueuedRecordCount: recovered.queuedRecordCount,
                finalSpooledRecordCount: recovered.spooledRecordCount,
                finalActiveTaskCount: recovered.activeTaskCount,
                maximumTaskCount: recovered.maximumObservedTaskCount,
                taskLimit: recovered.taskLimit
            ),
            named: artifactName("hls-playback-analytics-recovery")
        )

        weak var releasedDelivery: PlaybackAnalyticsDelivery?
        do {
            let lifetimeSink = QualificationSwitchableSink(mode: .online)
            let lifetimeDelivery = PlaybackAnalyticsDelivery(sink: lifetimeSink)
            releasedDelivery = lifetimeDelivery
            await lifetimeDelivery.record(event)
            let didReleaseCleanly = await lifetimeDelivery.shutdown()
            XCTAssertTrue(didReleaseCleanly)
        }
        for _ in 0..<10 where releasedDelivery != nil { await Task.yield() }
        XCTAssertNil(releasedDelivery)
    }

    func testCanonicalAndSpooledPayloadsExcludeSensitiveAndUnapprovedData() async throws {
        let privateURL = try XCTUnwrap(URL(
            string: "https://secret.example/private.m3u8?token=credential-123"
        ))
        let unapprovedItemID = "secret-feed-item-42"
        let timeline = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: 16,
            summaryBufferCapacity: 4
        ))
        let attempt = timeline.beginAttempt(attribution: .init(
            reuse: .cold,
            intent: .predicted,
            mediaKind: .videoOnDemand
        ))
        timeline.record(prepared: FeedPreparedItem(
            itemID: .init(rawValue: unapprovedItemID),
            generation: .init(rawValue: 1),
            manifestURLs: [privateURL],
            mediaPlaylistCount: 1,
            leadingSegmentCount: 2,
            preparedResourceCount: 3,
            preparedByteCount: 4_096,
            cacheHitCount: 1,
            originFetchCount: 2,
            cacheHitByteCount: 1_024,
            originFetchByteCount: 3_072
        ), attempt: attempt)
        timeline.record(
            player: .init(status: .failed(
                "Authorization: Bearer credential-123 from 203.0.113.42"
            )),
            attempt: attempt
        )
        timeline.end(attempt, reason: .failed)
        timeline.finish()
        let events = await collect(timeline.events)
        let summaries = await collect(timeline.summaries)
        let records = events.map(PlaybackAnalyticsRecord.event)
            + summaries.map(PlaybackAnalyticsRecord.summary)
        let canonical = try PlaybackAnalyticsExportCodec.encodeJSONLines(
            .init(records: records)
        )
        let batchEncoding = try JSONEncoder().encode(PlaybackAnalyticsBatch(records: records))

        let spoolRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PlaybackAnalyticsPrivacy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: spoolRoot) }
        let offlineSink = QualificationSwitchableSink(mode: .offline)
        let delivery = PlaybackAnalyticsDelivery(
            sink: offlineSink,
            configuration: .init(
                memoryBudgetBytes: 32 * 1_024,
                maximumQueuedRecordCount: 32,
                maximumBatchBytes: 16 * 1_024,
                maximumBatchRecordCount: 16,
                flushInterval: .seconds(999),
                retryPolicy: .init(maximumAttempts: 1),
                diskSpool: .init(
                    directory: spoolRoot,
                    maximumBytes: 32 * 1_024,
                    maximumRecordCount: 32
                )
            )
        )
        for record in records {
            switch record {
            case .event(let event): await delivery.record(event)
            case .summary(let summary): await delivery.record(summary)
            }
        }
        await delivery.flush()
        _ = await delivery.shutdown(flushTimeout: .zero)
        let spoolPayload = try recursiveFileData(in: spoolRoot)
        let payloads = [canonical, batchEncoding, spoolPayload]
        let forbiddenPatterns = [
            "https://", "http://", "secret.example", "private.m3u8",
            "203.0.113.42", "authorization", "bearer", "cookie",
            "credential-123", "requestheaders", "request_headers",
            "responseheaders", "response_headers", "useridentifier",
            "user_identifier", "ipaddress", "rawmediaurl", unapprovedItemID,
        ]
        for payload in payloads {
            let text = String(decoding: payload, as: UTF8.self).lowercased()
            for pattern in forbiddenPatterns {
                XCTAssertFalse(text.contains(pattern.lowercased()), pattern)
            }
        }
        XCTAssertEqual(Set(records.map(\.idempotencyID)).count, records.count)
        XCTAssertEqual(
            Set(records.flatMap(Self.correlationIdentifiers)).count,
            3
        )

        try QualificationArtifact.write(
            PrivacyReport(
                configuration: artifactConfiguration,
                encodedRecordCount: records.count,
                scannedPayloadBytes: canonical.count + batchEncoding.count,
                scannedSpoolBytes: spoolPayload.count,
                forbiddenPatternCount: forbiddenPatterns.count,
                opaqueIdentifierCount: records.count + 3
            ),
            named: artifactName("hls-playback-analytics-privacy")
        )

        weak var releasedTimeline: PlaybackAnalyticsTimeline?
        do {
            let lifetimeTimeline = PlaybackAnalyticsTimeline()
            releasedTimeline = lifetimeTimeline
            lifetimeTimeline.finish()
        }
        XCTAssertNil(releasedTimeline)
    }

    private var artifactConfiguration: String {
        ProcessInfo.processInfo.environment["HLS_ANALYTICS_QUALIFICATION_CONFIGURATION"]
            ?? "debug"
    }

    private func artifactName(_ base: String) -> String {
        "\(base)-\(artifactConfiguration).json"
    }

    private func makeEvent(
        correlation: PlaybackAnalytics.Correlation,
        clock: PlaybackAnalytics.TimelineClock = .init(),
        lifecycle: PlaybackAnalytics.Lifecycle = .ready,
        priority: PlaybackAnalytics.Priority = .routine,
        measurements: [PlaybackAnalytics.Measurement] = []
    ) throws -> PlaybackAnalytics.Event {
        try PlaybackAnalytics.Event(
            correlation: correlation,
            timestamp: clock.timestamp(),
            source: .feedEngine,
            lifecycle: lifecycle,
            priority: priority,
            measurements: measurements
        )
    }

    private func makeSummary(
        correlation: PlaybackAnalytics.Correlation
    ) throws -> PlaybackAnalytics.Summary {
        let clock = PlaybackAnalytics.TimelineClock()
        return try PlaybackAnalytics.Summary(
            correlation: correlation,
            startedAt: clock.timestamp(),
            endedAt: clock.timestamp(),
            terminalReason: .completed
        )
    }

    private func collect<Value>(_ stream: AsyncStream<Value>) async -> [Value] {
        var values: [Value] = []
        for await value in stream { values.append(value) }
        return values
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for analytics qualification state")
    }

    private func recursiveFileData(in root: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: root.path) else { return Data() }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys
            )
        )
        var payload = Data()
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: Set(keys)).isRegularFile == true {
                payload.append(try Data(contentsOf: url))
            }
        }
        return payload
    }

    private static func droppedRecordCount(
        _ snapshot: PlaybackAnalyticsDelivery.Snapshot
    ) -> UInt64 {
        snapshot.droppedRoutineRecordCount
            + snapshot.droppedImportantRecordCount
            + snapshot.droppedCriticalRecordCount
    }

    private static func correlationIdentifiers(
        _ record: PlaybackAnalyticsRecord
    ) -> [String] {
        let correlation = switch record {
        case .event(let event): event.correlation
        case .summary(let summary): summary.correlation
        }
        return [
            correlation.sessionID.encodedValue,
            correlation.playbackID.encodedValue,
            correlation.itemID.encodedValue,
        ]
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private enum QualificationSinkError: Error, PlaybackAnalyticsRetryClassifyingError {
    case offline

    var retryDisposition: PlaybackAnalyticsRetryDisposition { .retryable }
}

private actor QualificationSwitchableSink: PlaybackAnalyticsSink {
    enum Mode: Sendable {
        case blocked
        case offline
        case online
    }

    private var mode: Mode
    private var attempts = 0
    private var records: [PlaybackAnalyticsRecord] = []
    private var blockedContinuations: [CheckedContinuation<Void, Never>] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var attemptCount: Int { attempts }
    var deliveredRecords: [PlaybackAnalyticsRecord] { records }

    func setMode(_ mode: Mode) {
        self.mode = mode
        guard mode == .online else { return }
        let continuations = blockedContinuations
        blockedContinuations.removeAll(keepingCapacity: false)
        for continuation in continuations { continuation.resume() }
    }

    func send(_ batch: PlaybackAnalyticsBatch) async throws {
        attempts += 1
        switch mode {
        case .blocked:
            await withCheckedContinuation { continuation in
                blockedContinuations.append(continuation)
            }
            try Task.checkCancellation()
            records.append(contentsOf: batch.records)
        case .offline:
            throw QualificationSinkError.offline
        case .online:
            records.append(contentsOf: batch.records)
        }
    }
}
