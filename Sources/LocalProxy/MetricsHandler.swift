import Foundation
import HLSCore

public struct MetricsHandler: Sendable {
    private let cache: HLSSegmentCache
    private let scheduler: SegmentPrefetchScheduler
    private let telemetry: HLSStreamingTelemetry?

    public init(
        cache: HLSSegmentCache,
        scheduler: SegmentPrefetchScheduler,
        telemetry: HLSStreamingTelemetry? = nil
    ) {
        self.cache = cache
        self.scheduler = scheduler
        self.telemetry = telemetry
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable _ in
            async let cacheMetrics = cache.metrics()
            async let bufferState = scheduler.bufferState()
            let (metrics, buffer) = await (cacheMetrics, bufferState)
            let streaming: HLSStreamingTelemetry.Snapshot?
            if let telemetry {
                await telemetry.updateCacheMetrics(metrics)
                streaming = await telemetry.snapshot()
            } else {
                streaming = nil
            }

            var body = """
            # HELP hlsproxy_cache_hits Total number of cache hits
            # TYPE hlsproxy_cache_hits counter
            hlsproxy_cache_hits \(metrics.hitCount)
            # HELP hlsproxy_cache_misses Total number of cache misses
            # TYPE hlsproxy_cache_misses counter
            hlsproxy_cache_misses \(metrics.missCount)
            # HELP hlsproxy_cache_bytes Number of bytes stored in cache memory
            hlsproxy_cache_bytes \(metrics.totalBytes)
            # HELP hlsproxy_cache_disk_bytes Number of bytes spilled to disk
            hlsproxy_cache_disk_bytes \(metrics.diskBytes)
            \(namespaceMetricsBody(metrics))
            # HELP hlsproxy_buffer_depth_seconds Prefetch depth in seconds
            # TYPE hlsproxy_buffer_depth_seconds gauge
            hlsproxy_buffer_depth_seconds \(buffer.prefetchDepthSeconds)
            # HELP hlsproxy_buffer_ready_segments Ready segment count
            # TYPE hlsproxy_buffer_ready_segments gauge
            hlsproxy_buffer_ready_segments \(buffer.readySequences.count)
            # HELP hlsproxy_buffer_ready_parts Ready part count
            # TYPE hlsproxy_buffer_ready_parts gauge
            hlsproxy_buffer_ready_parts \(buffer.readyPartCounts.values.reduce(0, +))
            # HELP hlsproxy_part_buffer_depth_seconds Part-prefetch depth in seconds
            # TYPE hlsproxy_part_buffer_depth_seconds gauge
            hlsproxy_part_buffer_depth_seconds \(buffer.partPrefetchDepthSeconds)
            """

            if let streaming {
                body += "\n" + streamingMetricsBody(streaming)
            }

            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "text/plain; version=0.0.4"],
                body: Data(body.utf8)
            )
        }
    }

    private func namespaceMetricsBody(_ metrics: HLSSegmentCache.Metrics) -> String {
        var lines = [
            "# HELP hlsproxy_cache_namespace_hits_total Cache hits by fixed media namespace",
            "# TYPE hlsproxy_cache_namespace_hits_total counter",
            "# HELP hlsproxy_cache_namespace_misses_total Cache misses by fixed media namespace",
            "# TYPE hlsproxy_cache_namespace_misses_total counter",
            "# HELP hlsproxy_cache_namespace_evictions_total Cache evictions by fixed media namespace and storage tier",
            "# TYPE hlsproxy_cache_namespace_evictions_total counter",
            "# HELP hlsproxy_cache_namespace_expirations_total Expired cache lookups by fixed media namespace",
            "# TYPE hlsproxy_cache_namespace_expirations_total counter"
        ]
        for namespace in HLSSegmentCache.Namespace.allCases {
            let value = metrics.metrics(for: namespace)
            let label = namespace.rawValue
            lines.append("hlsproxy_cache_namespace_hits_total{namespace=\"\(label)\"} \(value.hitCount)")
            lines.append("hlsproxy_cache_namespace_misses_total{namespace=\"\(label)\"} \(value.missCount)")
            lines.append("hlsproxy_cache_namespace_evictions_total{namespace=\"\(label)\",tier=\"memory\"} \(value.memoryEvictionCount)")
            lines.append("hlsproxy_cache_namespace_evictions_total{namespace=\"\(label)\",tier=\"disk\"} \(value.diskEvictionCount)")
            lines.append("hlsproxy_cache_namespace_expirations_total{namespace=\"\(label)\"} \(value.expirationCount)")
        }
        return lines.joined(separator: "\n")
    }

    private func streamingMetricsBody(_ snapshot: HLSStreamingTelemetry.Snapshot) -> String {
        let latency = snapshot.segmentFetchLatency
        var lines = [
            "# HELP hlsproxy_segment_fetch_duration_seconds End-to-end segment fetch latency including retry backoff",
            "# TYPE hlsproxy_segment_fetch_duration_seconds histogram"
        ]
        var cumulative: UInt64 = 0
        for (index, upperBound) in latency.upperBounds.enumerated() {
            cumulative &+= latency.bucketCounts[index]
            lines.append(
                "hlsproxy_segment_fetch_duration_seconds_bucket{le=\"\(upperBound)\"} \(cumulative)"
            )
        }
        cumulative &+= latency.bucketCounts.last ?? 0
        lines.append("hlsproxy_segment_fetch_duration_seconds_bucket{le=\"+Inf\"} \(cumulative)")
        lines.append("hlsproxy_segment_fetch_duration_seconds_count \(latency.count)")
        lines.append("hlsproxy_segment_fetch_duration_seconds_sum \(latency.sum)")

        lines.append("# HELP hlsproxy_segment_fetch_errors_total Terminal segment fetch errors by bounded category")
        lines.append("# TYPE hlsproxy_segment_fetch_errors_total counter")
        for category in HLSSegmentFetcher.FetchErrorCategory.allCases {
            lines.append(
                "hlsproxy_segment_fetch_errors_total{category=\"\(category.rawValue)\"} \(snapshot.fetchErrorCounts[category, default: 0])"
            )
        }

        lines.append("# HELP hlsproxy_segment_retry_outcomes_total Terminal segment retry outcomes")
        lines.append("# TYPE hlsproxy_segment_retry_outcomes_total counter")
        for outcome in HLSSegmentFetcher.RetryOutcome.allCases {
            lines.append(
                "hlsproxy_segment_retry_outcomes_total{outcome=\"\(outcome.rawValue)\"} \(snapshot.retryOutcomeCounts[outcome, default: 0])"
            )
        }

        lines.append("# HELP hlsproxy_cache_hit_ratio Cache hits divided by total cache lookups")
        lines.append("# TYPE hlsproxy_cache_hit_ratio gauge")
        lines.append("hlsproxy_cache_hit_ratio \(snapshot.cacheHitRatio ?? 0)")
        lines.append("# HELP hlsproxy_live_edge_distance_seconds Estimated media duration between playback and the live edge")
        lines.append("# TYPE hlsproxy_live_edge_distance_seconds gauge")
        let liveEdgeDistance = snapshot.liveEdgeDistanceSeconds.map { String($0) } ?? "NaN"
        lines.append("hlsproxy_live_edge_distance_seconds \(liveEdgeDistance)")

        lines.append("# HELP hlsproxy_variant_switches_total Successful adaptive variant switches by bounded reason")
        lines.append("# TYPE hlsproxy_variant_switches_total counter")
        for reason in snapshot.variantSwitchReasonCounts.keys.sorted() {
            let escaped = reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            lines.append(
                "hlsproxy_variant_switches_total{reason=\"\(escaped)\"} \(snapshot.variantSwitchReasonCounts[reason, default: 0])"
            )
        }
        return lines.joined(separator: "\n")
    }
}
