import Foundation
@testable import ProxyPlayerKit
import XCTest

final class PlaybackAnalyticsDeliveryTests: XCTestCase {
    func testBatchesRetriesWithDeterministicClockAndPreservesIdempotency() async throws {
        let sink = ScriptedAnalyticsSink(failuresBeforeSuccess: 2)
        let sleeps = DeliverySleepRecorder()
        let flushInterval = Duration.seconds(999)
        let clock = PlaybackAnalyticsDelivery.Clock { duration in
            if duration == flushInterval {
                try await Task.sleep(for: .seconds(60))
            } else {
                await sleeps.append(duration)
            }
        }
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                maximumBatchRecordCount: 8,
                flushInterval: flushInterval,
                retryPolicy: .init(
                    maximumAttempts: 3,
                    initialDelay: .milliseconds(10),
                    multiplier: 2,
                    maximumDelay: .seconds(1)
                )
            ),
            clock: clock
        )
        let events = try (0..<3).map { _ in try makeEvent() }

        for event in events {
            await delivery.record(event)
        }
        await delivery.flush()

        let attempts = await sink.attemptedBatches()
        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(attempts.allSatisfy { $0.idempotencyIDs == events.map(\.recordID) })
        let retrySleeps = await sleeps.values()
        XCTAssertEqual(retrySleeps, [.milliseconds(10), .milliseconds(20)])
        let snapshot = await delivery.snapshot
        XCTAssertEqual(snapshot.deliveredRecordCount, 3)
        XCTAssertEqual(snapshot.deliveredBatchCount, 1)
        XCTAssertEqual(snapshot.retryCount, 2)
        XCTAssertEqual(snapshot.exportFailureCount, 2)
        XCTAssertEqual(snapshot.queuedRecordCount, 0)
        XCTAssertLessThanOrEqual(snapshot.maximumObservedTaskCount, 1)
        let didShutdownCleanly = await delivery.shutdown()
        XCTAssertTrue(didShutdownCleanly)
    }

    func testSlowSinkCannotBreakMemoryRecordOrTaskBoundsAndCriticalSummaryWins() async throws {
        let sink = ScriptedAnalyticsSink(blocksUntilCancelled: true)
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                memoryBudgetBytes: 4_096,
                maximumQueuedRecordCount: 4,
                maximumBatchRecordCount: 1,
                flushInterval: .zero,
                shutdownFlushTimeout: .zero,
                retryPolicy: .init(maximumAttempts: 1)
            )
        )
        await delivery.record(try makeEvent())
        try await waitUntil { await sink.attemptCount() == 1 }

        for _ in 0..<100 {
            await delivery.record(try makeEvent())
        }
        await delivery.record(try makeSummary())

        let bounded = await delivery.snapshot
        XCTAssertLessThanOrEqual(bounded.queuedRecordCount, 4)
        XCTAssertLessThanOrEqual(bounded.queuedBytes, 4_096)
        XCTAssertEqual(bounded.maximumQueuedRecordCount, 4)
        XCTAssertEqual(bounded.memoryBudgetBytes, 4_096)
        XCTAssertLessThanOrEqual(bounded.maximumObservedQueuedRecordCount, 4)
        XCTAssertLessThanOrEqual(bounded.maximumObservedQueuedBytes, 4_096)
        XCTAssertGreaterThan(bounded.droppedRoutineRecordCount, 0)
        XCTAssertEqual(bounded.droppedCriticalRecordCount, 0)
        XCTAssertLessThanOrEqual(bounded.maximumObservedTaskCount, 1)
        XCTAssertLessThanOrEqual(bounded.maximumObservedTaskCount, bounded.taskLimit)

        let didShutdownCleanly = await delivery.shutdown(flushTimeout: .zero)
        XCTAssertTrue(didShutdownCleanly)
        let stopped = await delivery.snapshot
        XCTAssertFalse(stopped.isAcceptingRecords)
        XCTAssertEqual(stopped.activeTaskCount, 0)
    }

    func testFailedBatchUsesBoundedPriorityAwareDiskSpoolAndReplays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PlaybackAnalyticsDeliveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = ScriptedAnalyticsSink(failuresBeforeSuccess: 1)
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                memoryBudgetBytes: 8_192,
                maximumBatchBytes: 8_192,
                maximumBatchRecordCount: 8,
                flushInterval: .seconds(999),
                retryPolicy: .init(maximumAttempts: 1),
                diskSpool: .init(
                    directory: directory,
                    maximumBytes: 8_192,
                    maximumRecordCount: 1
                )
            )
        )

        await delivery.record(try makeEvent(priority: .routine))
        let summary = try makeSummary()
        await delivery.record(summary)
        await delivery.flush()

        let spooled = await delivery.snapshot
        XCTAssertEqual(spooled.spooledRecordCount, 1)
        XCTAssertLessThanOrEqual(spooled.spooledBytes, 8_192)
        XCTAssertEqual(spooled.maximumSpooledRecordCount, 1)
        XCTAssertEqual(spooled.maximumSpoolBytes, 8_192)
        XCTAssertEqual(spooled.droppedRoutineRecordCount, 1)
        XCTAssertEqual(spooled.droppedCriticalRecordCount, 0)

        let spoolDirectory = directory.appendingPathComponent(
            "hlsproxy-playback-analytics-v1",
            isDirectory: true
        )
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: spoolDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let persisted = try JSONDecoder().decode(
            PlaybackAnalyticsRecord.self,
            from: Data(contentsOf: file)
        )
        XCTAssertEqual(persisted, .summary(summary))

        await delivery.flush()
        let replayed = await delivery.snapshot
        XCTAssertEqual(replayed.spooledRecordCount, 0)
        XCTAssertEqual(replayed.deliveredRecordCount, 1)
        let attemptCount = await sink.attemptCount()
        XCTAssertEqual(attemptCount, 2)
        let didShutdownCleanly = await delivery.shutdown()
        XCTAssertTrue(didShutdownCleanly)
    }

    func testRoutineSamplingNeverSamplesImportantEventsOrSummaries() async throws {
        let sink = ScriptedAnalyticsSink()
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                routineSamplingRate: 0,
                flushInterval: .seconds(999),
                retryPolicy: .init(maximumAttempts: 1)
            )
        )
        await delivery.record(try makeEvent(priority: .routine))
        let important = try makeEvent(priority: .important)
        let summary = try makeSummary()
        await delivery.record(important)
        await delivery.record(summary)
        await delivery.flush()

        let records = await sink.successfulRecords()
        XCTAssertEqual(records, [.event(important), .summary(summary)])
        let snapshot = await delivery.snapshot
        XCTAssertEqual(snapshot.sampledOutRecordCount, 1)
        XCTAssertEqual(snapshot.deliveredRecordCount, 2)
        let didShutdownCleanly = await delivery.shutdown()
        XCTAssertTrue(didShutdownCleanly)
    }

    func testShutdownFlushesBestEffortRejectsNewRecordsAndFinishesHealthStream() async throws {
        let sink = ScriptedAnalyticsSink()
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(
                flushInterval: .seconds(999),
                retryPolicy: .init(maximumAttempts: 1)
            )
        )
        let event = try makeEvent()
        await delivery.record(event)

        let healthTask = Task { () -> [PlaybackAnalyticsDelivery.Snapshot] in
            var values: [PlaybackAnalyticsDelivery.Snapshot] = []
            for await value in delivery.snapshots {
                values.append(value)
            }
            return values
        }
        let didShutdownCleanly = await delivery.shutdown(flushTimeout: .seconds(1))
        XCTAssertTrue(didShutdownCleanly)
        await delivery.record(try makeEvent())

        let health = await healthTask.value
        XCTAssertFalse(health.isEmpty)
        let successfulRecords = await sink.successfulRecords()
        XCTAssertEqual(successfulRecords, [.event(event)])
        let snapshot = await delivery.snapshot
        XCTAssertFalse(snapshot.isAcceptingRecords)
        XCTAssertEqual(snapshot.droppedRoutineRecordCount, 1)
        XCTAssertEqual(snapshot.activeTaskCount, 0)
    }

    private func makeEvent(
        priority: PlaybackAnalytics.Priority = .routine
    ) throws -> PlaybackAnalytics.Event {
        try PlaybackAnalytics.Event(
            correlation: makeCorrelation(),
            timestamp: PlaybackAnalytics.TimelineClock().timestamp(),
            source: .feedEngine,
            lifecycle: .ready,
            priority: priority
        )
    }

    private func makeSummary() throws -> PlaybackAnalytics.Summary {
        let clock = PlaybackAnalytics.TimelineClock()
        return try PlaybackAnalytics.Summary(
            correlation: makeCorrelation(),
            startedAt: clock.timestamp(),
            endedAt: clock.timestamp(),
            terminalReason: .completed
        )
    }

    private func makeCorrelation() -> PlaybackAnalytics.Correlation {
        .init(sessionID: .init(), playbackID: .init(), itemID: .init())
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for asynchronous delivery state")
    }
}

private enum ScriptedSinkError: Error {
    case unavailable
}

private actor ScriptedAnalyticsSink: PlaybackAnalyticsSink {
    private var failuresBeforeSuccess: Int
    private let blocksUntilCancelled: Bool
    private var attempts: [PlaybackAnalyticsBatch] = []
    private var successes: [PlaybackAnalyticsRecord] = []

    init(failuresBeforeSuccess: Int = 0, blocksUntilCancelled: Bool = false) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func send(_ batch: PlaybackAnalyticsBatch) async throws {
        attempts.append(batch)
        if blocksUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw ScriptedSinkError.unavailable
        }
        successes.append(contentsOf: batch.records)
    }

    func attemptCount() -> Int {
        attempts.count
    }

    func attemptedBatches() -> [PlaybackAnalyticsBatch] {
        attempts
    }

    func successfulRecords() -> [PlaybackAnalyticsRecord] {
        successes
    }
}

private actor DeliverySleepRecorder {
    private var durations: [Duration] = []

    func append(_ duration: Duration) {
        durations.append(duration)
    }

    func values() -> [Duration] {
        durations
    }
}
