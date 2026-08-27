import XCTest
@testable import ProxyPlayerKit

@MainActor
final class PlaybackSessionSummaryTests: XCTestCase {
    func testReconcilesBoundedFleetMetricsAndSnapshotEvents() throws {
        let correlation = PlaybackAnalytics.Correlation(
            sessionID: .init(),
            playbackID: .init(),
            itemID: .init()
        )
        let anchor = PlaybackAnalytics.ClockAnchor(unixMilliseconds: 1_700_000_000_000)
        var summarizer = PlaybackSessionSummarizer(
            correlation: correlation,
            startedAt: timestamp(0, anchor: anchor)
        )

        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 0.2,
            lifecycle: .playbackStarted,
            measurements: [
                measurement("first_frame_latency", 0.2, .seconds),
            ]
        ))
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 2,
            lifecycle: .resourceCompleted,
            measurements: [
                measurement("cache_hit_count", 3, .count),
                measurement("cache_miss_count", 1, .count),
                measurement("origin_bytes", 1_024, .bytes),
                measurement("origin_bytes_avoided", 512, .bytes),
                measurement("wasted_bytes", 64, .bytes),
                measurement("memory_resident_bytes", 4_096, .bytes),
                measurement("disk_resident_bytes", 8_192, .bytes),
                measurement("player_pool_occupancy", 2, .count),
                measurement("proxy_pool_occupancy", 1, .count),
            ]
        ))
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 4,
            lifecycle: .stalled,
            measurements: [
                measurement("stall_count", 1, .count),
                measurement("stall_duration", 2, .seconds),
            ]
        ))
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 6,
            lifecycle: .variantSwitched,
            measurements: [
                measurement("average_bitrate", 1_000_000, .bitsPerSecond),
                measurement("peak_bitrate", 2_000_000, .bitsPerSecond),
                measurement("variant_switch_success_count", 1, .count),
            ]
        ))
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 8,
            lifecycle: .handoffCompleted,
            measurements: [
                measurement("handoff_attempt_count", 2, .count),
                measurement("handoff_ready_count", 1, .count),
                measurement("handoff_success_count", 1, .count),
                measurement("cancellation_acknowledged_count", 1, .count),
                measurement("live_edge_distance", 1.5, .seconds),
                measurement("stitched_boundary_success_count", 1, .count),
            ]
        ))
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 10,
            lifecycle: .summaryEmitted,
            measurements: [
                measurement("stall_count", 2, .count),
                measurement("stall_recovery_duration", 3, .seconds),
                measurement("variant_switch_count", 4, .count),
                measurement("recoverable_error_count", 3, .count),
                measurement("watch_duration", 10, .seconds),
                measurement("startup_duration", 0.15, .seconds),
                measurement("average_bitrate", 1_500_000, .bitsPerSecond),
                measurement("peak_bitrate", 2_500_000, .bitsPerSecond),
            ]
        ))

        let dimensions = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "feed_intent": ["focused", "predicted"],
            "media_kind": ["vod", "live", "stitched"],
        ]).dimensions(from: [
            "cache_reuse": "warm",
            "feed_intent": "focused",
            "media_kind": "stitched",
        ])
        let summary = try summarizer.finish(
            reason: .completed,
            endedAt: timestamp(12, anchor: anchor),
            dimensions: dimensions
        )
        let values = Dictionary(uniqueKeysWithValues: summary.measurements.map {
            ($0.name.encodedValue, $0.value)
        })

        XCTAssertEqual(summary.terminalReason, .completed)
        XCTAssertEqual(summary.dimensions, dimensions)
        XCTAssertEqual(summary.measurements.count, 32)
        XCTAssertEqual(summarizer.recordedEventCount, 6)
        XCTAssertEqual(values["startup_duration"], 0.15)
        XCTAssertEqual(values["first_frame_latency"], 0.2)
        XCTAssertEqual(values["startup_abandonment_count"], 0)
        XCTAssertEqual(
            try XCTUnwrap(values["watch_duration"]),
            11.8,
            accuracy: 0.000_001
        )
        XCTAssertEqual(values["completion_count"], 1)
        XCTAssertEqual(values["stall_count"], 2)
        XCTAssertEqual(values["stall_duration"], 3)
        XCTAssertEqual(
            try XCTUnwrap(values["rebuffer_ratio"]),
            3 / 14.8,
            accuracy: 0.000_001
        )
        XCTAssertEqual(values["average_bitrate"], 1_250_000)
        XCTAssertEqual(values["peak_bitrate"], 2_500_000)
        XCTAssertEqual(values["variant_switch_count"], 4)
        XCTAssertEqual(values["recoverable_error_count"], 3)
        XCTAssertEqual(values["cache_hit_rate"], 0.75)
        XCTAssertEqual(values["origin_bytes"], 1_024)
        XCTAssertEqual(values["origin_bytes_avoided"], 512)
        XCTAssertEqual(values["cancellation_count"], 1)
        XCTAssertEqual(values["wasted_bytes"], 64)
        XCTAssertEqual(values["handoff_readiness_rate"], 0.5)
        XCTAssertEqual(values["handoff_success_rate"], 0.5)
        XCTAssertEqual(values["live_edge_distance"], 1.5)
        XCTAssertEqual(values["stitched_boundary_success_count"], 1)
        XCTAssertEqual(values["peak_memory_resident_bytes"], 4_096)
        XCTAssertEqual(values["peak_disk_resident_bytes"], 8_192)
        XCTAssertEqual(values["peak_player_pool_occupancy"], 2)
        XCTAssertEqual(values["peak_proxy_pool_occupancy"], 1)
        XCTAssertThrowsError(try summarizer.finish(
            reason: .completed,
            endedAt: timestamp(13, anchor: anchor)
        )) { error in
            XCTAssertEqual(error as? PlaybackSessionSummarizer.Error, .alreadyFinished)
        }
    }

    func testTerminalReasonsAndUnknownMeasurementsHaveExplicitNilRules() throws {
        let reasons: [PlaybackAnalytics.TerminalReason] = [
            .abandonedBeforeStart,
            .backgrounded,
            .crashed,
            .cancelled,
            .incomplete,
        ]

        for reason in reasons {
            let correlation = PlaybackAnalytics.Correlation(
                sessionID: .init(),
                playbackID: .init(),
                itemID: .init()
            )
            let anchor = PlaybackAnalytics.ClockAnchor(unixMilliseconds: 100)
            var summarizer = PlaybackSessionSummarizer(
                correlation: correlation,
                startedAt: timestamp(0, anchor: anchor)
            )
            let summary = try summarizer.finish(
                reason: reason,
                endedAt: timestamp(1, anchor: anchor)
            )
            let values = Dictionary(uniqueKeysWithValues: summary.measurements.map {
                ($0.name.encodedValue, $0.value)
            })

            XCTAssertEqual(summary.terminalReason, reason)
            XCTAssertEqual(values["startup_abandonment_count"], 1)
            XCTAssertEqual(values["watch_duration"], 0)
            XCTAssertNil(values["first_frame_latency"])
            XCTAssertNil(values["startup_duration"])
            XCTAssertNil(values["rebuffer_ratio"])
            XCTAssertNil(values["cache_hit_rate"])
            XCTAssertNil(values["handoff_success_rate"])
            XCTAssertNil(values["live_edge_distance"])
            XCTAssertEqual(values["fatal_error_count"], reason == .crashed ? 1 : 0)
            XCTAssertEqual(values["cancellation_count"], reason == .cancelled ? 1 : 0)
            XCTAssertEqual(
                try PlaybackAnalytics.Codec.decodeSummary(
                    from: PlaybackAnalytics.Codec.encode(summary)
                ).terminalReason,
                reason
            )
        }
    }

    func testRejectsCrossAttemptAndInconsistentClockEvents() throws {
        let correlation = PlaybackAnalytics.Correlation(
            sessionID: .init(),
            playbackID: .init(),
            itemID: .init()
        )
        let anchor = PlaybackAnalytics.ClockAnchor(unixMilliseconds: 100)
        var summarizer = PlaybackSessionSummarizer(
            correlation: correlation,
            startedAt: timestamp(1, anchor: anchor)
        )

        let otherCorrelation = PlaybackAnalytics.Correlation(
            sessionID: correlation.sessionID,
            playbackID: .init(),
            itemID: correlation.itemID
        )
        XCTAssertThrowsError(try summarizer.record(event(
            correlation: otherCorrelation,
            anchor: anchor,
            seconds: 2,
            lifecycle: .ready
        ))) { error in
            XCTAssertEqual(error as? PlaybackSessionSummarizer.Error, .correlationMismatch)
        }
        XCTAssertThrowsError(try summarizer.record(event(
            correlation: correlation,
            anchor: .init(unixMilliseconds: 101),
            seconds: 2,
            lifecycle: .ready
        ))) { error in
            XCTAssertEqual(error as? PlaybackSessionSummarizer.Error, .inconsistentClockAnchor)
        }
        XCTAssertThrowsError(try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 0,
            lifecycle: .ready
        ))) { error in
            XCTAssertEqual(error as? PlaybackSessionSummarizer.Error, .timestampBeforeStart)
        }
    }

    func testObservedCompletionReconcilesLaterRoutineCleanup() throws {
        let correlation = PlaybackAnalytics.Correlation(
            sessionID: .init(),
            playbackID: .init(),
            itemID: .init()
        )
        let anchor = PlaybackAnalytics.ClockAnchor(unixMilliseconds: 100)
        var summarizer = PlaybackSessionSummarizer(
            correlation: correlation,
            startedAt: timestamp(0, anchor: anchor)
        )
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 0.1,
            lifecycle: .playbackStarted
        ))
        try summarizer.record(event(
            correlation: correlation,
            anchor: anchor,
            seconds: 3,
            lifecycle: .completed,
            measurements: [measurement("completion_count", 1, .count)]
        ))

        let summary = try summarizer.finish(
            reason: .cancelled,
            endedAt: timestamp(4, anchor: anchor)
        )
        let values = Dictionary(uniqueKeysWithValues: summary.measurements.map {
            ($0.name.encodedValue, $0.value)
        })
        XCTAssertEqual(summary.terminalReason, .completed)
        XCTAssertEqual(values["completion_count"], 1)
        XCTAssertEqual(values["cancellation_count"], 0)
        XCTAssertEqual(values["first_frame_latency"], 0.1)
    }

    func testTimelineEmitsExactlyOneSummaryForTerminalEvictedAndFinishedAttempts() async {
        let timeline = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: 16,
            summaryBufferCapacity: 8,
            maximumActiveAttemptCount: 1
        ))
        let attribution = PlaybackAnalyticsTimeline.Attribution(
            reuse: .cold,
            intent: .predicted,
            mediaKind: .videoOnDemand
        )

        let evicted = timeline.beginAttempt(attribution: attribution)
        let cancelled = timeline.beginAttempt(attribution: attribution)
        timeline.end(cancelled, reason: .cancelled)
        let unfinished = timeline.beginAttempt(attribution: attribution)
        timeline.finish()

        let summaries = await collect(timeline.summaries)
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(summaries.map(\.correlation), [
            evicted.correlation,
            cancelled.correlation,
            unfinished.correlation,
        ])
        XCTAssertEqual(summaries.map(\.terminalReason), [
            .incomplete,
            .cancelled,
            .incomplete,
        ])
        XCTAssertEqual(timeline.snapshot.emittedSummaryCount, 3)
        XCTAssertEqual(timeline.snapshot.droppedSummaryCount, 0)
        XCTAssertEqual(timeline.snapshot.activeAttemptCount, 0)
        XCTAssertEqual(Set(summaries.map(\.recordID)).count, 3)
    }

    func testTimelineBoundsSummaryBackpressureAndReportsDrops() async {
        let timeline = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: 1,
            summaryBufferCapacity: 1,
            maximumActiveAttemptCount: 1
        ))
        let attribution = PlaybackAnalyticsTimeline.Attribution(
            reuse: .warm,
            intent: .focused,
            mediaKind: .live
        )
        var latest: PlaybackAnalyticsTimeline.Attempt?
        for _ in 0..<3 {
            let attempt = timeline.beginAttempt(attribution: attribution)
            timeline.end(attempt, reason: .cancelled)
            latest = attempt
        }
        timeline.finish()

        let summaries = await collect(timeline.summaries)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.correlation, latest?.correlation)
        XCTAssertEqual(timeline.snapshot.emittedSummaryCount, 3)
        XCTAssertEqual(timeline.snapshot.droppedSummaryCount, 2)
    }

    private func event(
        correlation: PlaybackAnalytics.Correlation,
        anchor: PlaybackAnalytics.ClockAnchor,
        seconds: Double,
        lifecycle: PlaybackAnalytics.Lifecycle,
        measurements: [PlaybackAnalytics.Measurement] = []
    ) throws -> PlaybackAnalytics.Event {
        try PlaybackAnalytics.Event(
            correlation: correlation,
            timestamp: timestamp(seconds, anchor: anchor),
            source: .feedEngine,
            lifecycle: lifecycle,
            measurements: measurements
        )
    }

    private func timestamp(
        _ seconds: Double,
        anchor: PlaybackAnalytics.ClockAnchor
    ) -> PlaybackAnalytics.Timestamp {
        .init(
            anchor: anchor,
            elapsedNanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
        )
    }

    private func measurement(
        _ name: String,
        _ value: Double,
        _ unit: PlaybackAnalytics.MeasurementUnit
    ) throws -> PlaybackAnalytics.Measurement {
        try .init(name: .init(name), value: value, unit: unit)
    }

    private func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
        var values: [T] = []
        for await value in stream {
            values.append(value)
        }
        return values
    }
}
