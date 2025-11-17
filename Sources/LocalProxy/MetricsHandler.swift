import Foundation
import HLSCore

public struct MetricsHandler: Sendable {
    private let cache: HLSSegmentCache
    private let scheduler: SegmentPrefetchScheduler

    public init(cache: HLSSegmentCache, scheduler: SegmentPrefetchScheduler) {
        self.cache = cache
        self.scheduler = scheduler
    }

    public func makeHandler() -> ProxyRouter.Handler {
        { @Sendable _ in
            async let cacheMetrics = cache.metrics()
            async let bufferState = scheduler.bufferState()
            let (metrics, buffer) = await (cacheMetrics, bufferState)

            let body = """
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

            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "text/plain; version=0.0.4"],
                body: Data(body.utf8)
            )
        }
    }
}
