import XCTest
@testable import HLSCore

final class HLSStreamingTelemetryTests: XCTestCase {
    func testAggregatesLatencyErrorsAndRetryOutcomesWithoutSamples() async {
        let telemetry = HLSStreamingTelemetry(configuration: .init(
            latencyUpperBounds: [0.1, 0.5],
            maximumVariantReasonCardinality: 4
        ))

        await telemetry.recordFetch(event(
            duration: 0.05,
            outcome: .successWithoutRetry
        ))
        await telemetry.recordFetch(event(
            duration: 0.2,
            attempts: 2,
            outcome: .successAfterRetry
        ))
        await telemetry.recordFetch(event(
            duration: 1,
            attempts: 3,
            outcome: .failureAfterRetry,
            error: .httpServer
        ))

        let snapshot = await telemetry.snapshot()
        XCTAssertEqual(snapshot.segmentFetchLatency.upperBounds, [0.1, 0.5])
        XCTAssertEqual(snapshot.segmentFetchLatency.bucketCounts, [1, 1, 1])
        XCTAssertEqual(snapshot.segmentFetchLatency.count, 3)
        XCTAssertEqual(snapshot.segmentFetchLatency.sum, 1.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.segmentFetchLatency.minimum, 0.05)
        XCTAssertEqual(snapshot.segmentFetchLatency.maximum, 1)
        XCTAssertEqual(snapshot.segmentFetchLatency.approximateQuantile(0.5), 0.5)
        XCTAssertEqual(snapshot.segmentFetchLatency.approximateQuantile(0.95), 1)
        XCTAssertEqual(snapshot.fetchErrorCounts[.httpServer], 1)
        XCTAssertEqual(snapshot.retryOutcomeCounts[.successWithoutRetry], 1)
        XCTAssertEqual(snapshot.retryOutcomeCounts[.successAfterRetry], 1)
        XCTAssertEqual(snapshot.retryOutcomeCounts[.failureAfterRetry], 1)
        XCTAssertEqual(snapshot.originByteCount, 2_048)
        XCTAssertEqual(snapshot.originRetryCount, 3)
    }

    func testPublishesSchedulerStateAndResetClearsCrossLayerCounters() async {
        let telemetry = HLSStreamingTelemetry()
        var iterator = await telemetry.updates().makeAsyncIterator()
        _ = await iterator.next()

        await telemetry.recordFetch(event(
            duration: 0.2,
            attempts: 2,
            outcome: .successAfterRetry
        ))
        await telemetry.updateSchedulerTelemetry(
            scheduledCount: 8,
            readyCount: 6,
            failureCount: 2,
            readyPartCount: 3
        )

        var snapshot = await telemetry.snapshot()
        XCTAssertEqual(snapshot.originByteCount, 1_024)
        XCTAssertEqual(snapshot.originRetryCount, 1)
        XCTAssertEqual(snapshot.schedulerScheduledCount, 8)
        XCTAssertEqual(snapshot.schedulerReadyCount, 6)
        XCTAssertEqual(snapshot.schedulerFailureCount, 2)
        XCTAssertEqual(snapshot.schedulerReadyPartCount, 3)

        let published = await iterator.next()
        XCTAssertEqual(published?.schedulerScheduledCount, 8)
        XCTAssertEqual(published?.schedulerReadyPartCount, 3)

        await telemetry.reset()
        snapshot = await telemetry.snapshot()
        XCTAssertEqual(snapshot.originByteCount, 0)
        XCTAssertEqual(snapshot.originRetryCount, 0)
        XCTAssertEqual(snapshot.schedulerScheduledCount, 0)
        XCTAssertEqual(snapshot.schedulerReadyCount, 0)
        XCTAssertEqual(snapshot.schedulerFailureCount, 0)
        XCTAssertEqual(snapshot.schedulerReadyPartCount, 0)
    }

    func testTracksCacheRatioAndNormalizesLiveEdgeDistance() async throws {
        let telemetry = HLSStreamingTelemetry()

        await telemetry.updateCacheMetrics(.init(
            hitCount: 7,
            missCount: 3,
            memoryHitCount: 5,
            diskHitCount: 2,
            totalBytes: 100,
            diskBytes: 20
        ))
        await telemetry.updateLiveEdgeDistance(-4)

        var snapshot = await telemetry.snapshot()
        XCTAssertEqual(try XCTUnwrap(snapshot.cacheHitRatio), 0.7, accuracy: 0.0001)
        XCTAssertEqual(snapshot.memoryCacheHitCount, 5)
        XCTAssertEqual(snapshot.diskCacheHitCount, 2)
        XCTAssertEqual(snapshot.liveEdgeDistanceSeconds, 0)

        await telemetry.updateLiveEdgeDistance(.infinity)
        snapshot = await telemetry.snapshot()
        XCTAssertNil(snapshot.liveEdgeDistanceSeconds)
    }

    func testBoundsVariantReasonCardinality() async {
        let telemetry = HLSStreamingTelemetry(configuration: .init(
            maximumVariantReasonCardinality: 2
        ))

        await telemetry.recordVariantSwitch(reason: "throughput_increased")
        await telemetry.recordVariantSwitch(reason: "buffer_depleted")
        await telemetry.recordVariantSwitch(reason: "failure_downgrade")
        await telemetry.recordVariantSwitch(reason: "another_reason")

        let snapshot = await telemetry.snapshot()
        XCTAssertEqual(snapshot.variantSwitchReasonCounts["throughput_increased"], 1)
        XCTAssertEqual(snapshot.variantSwitchReasonCounts["buffer_depleted"], 1)
        XCTAssertEqual(snapshot.variantSwitchReasonCounts["other"], 2)
        XCTAssertEqual(snapshot.latestVariantSwitchReason, "other")
        XCTAssertLessThanOrEqual(snapshot.variantSwitchReasonCounts.count, 3)
    }

    func testAsyncUpdatesKeepOnlyNewestSnapshot() async {
        let telemetry = HLSStreamingTelemetry(configuration: .init(
            latencyUpperBounds: [1]
        ))
        var iterator = await telemetry.updates().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial?.segmentFetchLatency.count, 0)

        await telemetry.recordFetch(event(duration: 0.1, outcome: .successWithoutRetry))
        await telemetry.recordFetch(event(duration: 0.2, outcome: .successWithoutRetry))
        await telemetry.recordFetch(event(duration: 0.3, outcome: .successWithoutRetry))

        let newest = await iterator.next()
        XCTAssertEqual(newest?.segmentFetchLatency.count, 3)
    }

    func testConfigurationCapsHistogramStorage() {
        let configuration = HLSStreamingTelemetry.Configuration(
            latencyUpperBounds: Array(1...100).map(TimeInterval.init),
            maximumVariantReasonCardinality: 1_000
        )

        XCTAssertEqual(configuration.latencyUpperBounds.count, 32)
        XCTAssertEqual(configuration.maximumVariantReasonCardinality, 64)
    }

    private func event(
        duration: TimeInterval,
        attempts: Int = 1,
        outcome: HLSSegmentFetcher.RetryOutcome,
        error: HLSSegmentFetcher.FetchErrorCategory? = nil
    ) -> HLSSegmentFetcher.FetchEvent {
        HLSSegmentFetcher.FetchEvent(
            url: URL(string: "https://cdn.example.com/segment.ts")!,
            duration: duration,
            byteCount: error == nil ? 1_024 : 0,
            attemptCount: attempts,
            retryCount: attempts - 1,
            retryOutcome: outcome,
            errorCategory: error
        )
    }
}
