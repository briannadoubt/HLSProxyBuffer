import HLSCore
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class PlaybackAnalyticsTimelineTests: XCTestCase {
    func testCorrelatesEveryStreamingLayerIntoOneOrderedBoundedTimeline() async throws {
        let timeline = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: 32,
            maximumActiveAttemptCount: 2
        ))
        let attempt = timeline.beginAttempt(attribution: .init(
            reuse: .cold,
            intent: .predicted,
            mediaKind: .stitched
        ))

        timeline.record(prepared: FeedPreparedItem(
            itemID: "stitched",
            generation: .init(rawValue: 1),
            manifestURLs: [URL(string: "https://private.example/manifest.m3u8")!],
            mediaPlaylistCount: 2,
            leadingSegmentCount: 3,
            preparedResourceCount: 5,
            preparedByteCount: 8_192,
            cacheHitCount: 2,
            originFetchCount: 3,
            cacheHitByteCount: 2_048,
            originFetchByteCount: 6_144
        ), attempt: attempt)
        timeline.record(feed: .init(
            path: .init(reuse: .cold, intent: .predicted, mediaKind: .stitched),
            payload: .handoff(wasReady: true, succeeded: true)
        ), attempt: attempt)
        timeline.updateAttribution(.init(
            reuse: .warm,
            intent: .focused,
            mediaKind: .stitched
        ), for: attempt)
        timeline.record(streaming: streamingSnapshot(), attempt: attempt)
        timeline.record(
            player: .init(status: .ready, bufferDepthSeconds: 4),
            previous: .init(status: .buffering),
            attempt: attempt
        )
        let avEvent = try PlaybackAnalytics.Event(
            correlation: attempt.correlation,
            timestamp: PlaybackAnalytics.TimelineClock().timestamp(),
            source: .avFoundation,
            lifecycle: .rateChanged,
            measurements: [try .init(
                name: .init("playback_rate"),
                value: 1.25,
                unit: .scalar
            )]
        )
        timeline.record(avFoundation: avEvent, attempt: attempt)
        timeline.recordStitchedBoundary(succeeded: true, attempt: attempt)
        timeline.record(feed: .init(
            path: .init(reuse: .warm, intent: .focused, mediaKind: .stitched),
            payload: .cancellation(latency: 0.02, outcome: .acknowledged)
        ), attempt: attempt)
        timeline.end(attempt, lifecycle: .cancelled)
        timeline.finish()

        let events = await collect(timeline.events)
        XCTAssertEqual(events.count, 15)
        XCTAssertTrue(events.allSatisfy { $0.correlation == attempt.correlation })
        XCTAssertEqual(
            events.flatMap(\.measurements)
                .filter { $0.name.encodedValue == "timeline_sequence" }
                .map(\.value),
            Array(1...15).map(Double.init)
        )
        XCTAssertTrue(events.allSatisfy {
            $0.timestamp.anchor == events.first?.timestamp.anchor
        })

        let measurementNames = Set(events.flatMap(\.measurements).map(\.name.encodedValue))
        XCTAssertTrue(measurementNames.isSuperset(of: [
            "origin_bytes",
            "origin_bytes_avoided",
            "origin_retry_count",
            "cache_hit_count",
            "variant_switch_count",
            "live_edge_distance",
            "ready_part_count",
            "handoff_success_count",
            "stitched_boundary_success_count",
            "cancellation_acknowledged_count",
            "playback_rate",
        ]))
        XCTAssertTrue(events.contains {
            $0.dimensions.values["network_leg"] == "player_proxy"
        })
        XCTAssertTrue(events.contains {
            $0.dimensions.values["network_leg"] == "proxy_origin"
                && $0.dimensions.values["cache_tier"] == "origin"
        })
        XCTAssertTrue(events.contains { $0.dimensions.values["cache_tier"] == "memory" })
        XCTAssertTrue(events.contains { $0.dimensions.values["cache_tier"] == "disk" })
        XCTAssertEqual(events.last?.dimensions.values["cache_reuse"], "warm")
        XCTAssertEqual(events.last?.dimensions.values["feed_intent"], "focused")
        XCTAssertEqual(events.last?.dimensions.values["media_kind"], "stitched")

        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private.example"))
        XCTAssertFalse(encoded.contains("manifest.m3u8"))
        XCTAssertEqual(timeline.snapshot.activeAttemptCount, 0)
        XCTAssertEqual(timeline.snapshot.staleEventCount, 0)
    }

    func testEvictsOldAttemptsRejectsStaleGenerationsAndBoundsBackpressure() async {
        let timeline = PlaybackAnalyticsTimeline(configuration: .init(
            eventBufferCapacity: 1,
            maximumActiveAttemptCount: 1
        ))
        let attribution = PlaybackAnalyticsTimeline.Attribution(
            reuse: .cold,
            intent: .predicted,
            mediaKind: .videoOnDemand
        )
        let oldAttempt = timeline.beginAttempt(attribution: attribution)
        let currentAttempt = timeline.beginAttempt(attribution: attribution)
        timeline.record(
            source: .origin,
            lifecycle: .resourceCompleted,
            attempt: oldAttempt
        )
        timeline.end(currentAttempt, lifecycle: .completed)
        timeline.finish()
        _ = timeline.beginAttempt(attribution: attribution)

        let events = await collect(timeline.events)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.correlation, currentAttempt.correlation)
        XCTAssertEqual(events.first?.lifecycle, .completed)
        XCTAssertEqual(timeline.snapshot.activeAttemptCount, 0)
        XCTAssertEqual(timeline.snapshot.evictedAttemptCount, 1)
        XCTAssertEqual(timeline.snapshot.emittedEventCount, 3)
        XCTAssertEqual(timeline.snapshot.droppedEventCount, 2)
        XCTAssertEqual(timeline.snapshot.staleEventCount, 2)
    }

    private func streamingSnapshot() -> HLSStreamingTelemetry.Snapshot {
        .init(
            segmentFetchLatency: .init(
                upperBounds: [0.1],
                bucketCounts: [1, 1],
                count: 2,
                sum: 0.3,
                minimum: 0.1,
                maximum: 0.2
            ),
            fetchErrorCounts: [.httpServer: 1],
            retryOutcomeCounts: [.successAfterRetry: 1],
            cacheHitCount: 4,
            cacheMissCount: 2,
            memoryCacheHitCount: 3,
            diskCacheHitCount: 1,
            liveEdgeDistanceSeconds: 1.5,
            variantSwitchReasonCounts: ["throughput": 1],
            latestVariantSwitchReason: "throughput",
            originByteCount: 4_096,
            originRetryCount: 1,
            schedulerScheduledCount: 6,
            schedulerReadyCount: 5,
            schedulerFailureCount: 1,
            schedulerReadyPartCount: 2
        )
    }

    private func collect(
        _ stream: AsyncStream<PlaybackAnalytics.Event>
    ) async -> [PlaybackAnalytics.Event] {
        var values: [PlaybackAnalytics.Event] = []
        for await value in stream {
            values.append(value)
        }
        return values
    }
}
