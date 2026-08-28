import XCTest
@testable import HLSCore
@testable import LocalProxy

final class MetricsHandlerTests: XCTestCase {
    func testRendersBoundedStreamingMetrics() async throws {
        let cache = HLSSegmentCache(capacityBytes: 1_024)
        await cache.put(Data([0x01]), for: "hit")
        _ = await cache.get("hit")
        _ = await cache.get("miss")
        let scheduler = SegmentPrefetchScheduler()
        let telemetry = HLSStreamingTelemetry(configuration: .init(
            latencyUpperBounds: [0.1, 1]
        ))
        await telemetry.recordFetch(.init(
            url: URL(string: "https://cdn.example.com/segment.ts")!,
            duration: 0.2,
            byteCount: 0,
            attemptCount: 2,
            retryCount: 1,
            retryOutcome: .failureAfterRetry,
            errorCategory: .httpServer
        ))
        await telemetry.updateLiveEdgeDistance(2.5)
        await telemetry.recordVariantSwitch(reason: "buffer_depleted")

        let handler = MetricsHandler(
            cache: cache,
            scheduler: scheduler,
            telemetry: telemetry
        ).makeHandler()
        let response = await handler(HTTPRequest(
            method: .get,
            path: "/metrics",
            headers: [:],
            body: Data()
        ))
        let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))

        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(body.contains("hlsproxy_segment_fetch_duration_seconds_bucket{le=\"0.1\"} 0"))
        XCTAssertTrue(body.contains("hlsproxy_segment_fetch_duration_seconds_bucket{le=\"1.0\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_segment_fetch_duration_seconds_count 1"))
        XCTAssertTrue(body.contains("hlsproxy_segment_fetch_errors_total{category=\"http_server\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_segment_retry_outcomes_total{outcome=\"failure_after_retry\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_cache_hit_ratio 0.5"))
        XCTAssertTrue(body.contains("hlsproxy_cache_entries{tier=\"memory\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_cache_high_water_bytes{tier=\"memory\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_cache_evictions_total{reason=\"memory_pressure\"} 0"))
        XCTAssertTrue(body.contains("hlsproxy_cache_namespace_hits_total{namespace=\"video\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_cache_namespace_misses_total{namespace=\"video\"} 1"))
        XCTAssertTrue(body.contains("hlsproxy_cache_namespace_evictions_total{namespace=\"audio\",tier=\"disk\"} 0"))
        XCTAssertTrue(body.contains("hlsproxy_live_edge_distance_seconds 2.5"))
        XCTAssertTrue(body.contains("hlsproxy_variant_switches_total{reason=\"buffer_depleted\"} 1"))
    }
}
