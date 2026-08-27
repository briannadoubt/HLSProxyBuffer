import Foundation

/// Fixed-memory aggregation for operational streaming metrics.
public actor HLSStreamingTelemetry {
    public struct Configuration: Equatable, Sendable {
        public static let defaultLatencyUpperBounds: [TimeInterval] = [
            0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10
        ]

        public let latencyUpperBounds: [TimeInterval]
        public let maximumVariantReasonCardinality: Int

        public init(
            latencyUpperBounds: [TimeInterval] = Self.defaultLatencyUpperBounds,
            maximumVariantReasonCardinality: Int = 16
        ) {
            let normalizedBounds = Array(
                Set(latencyUpperBounds.filter { $0.isFinite && $0 > 0 })
            )
            .sorted()
            .prefix(32)
            self.latencyUpperBounds = normalizedBounds.isEmpty
                ? Self.defaultLatencyUpperBounds
                : Array(normalizedBounds)
            self.maximumVariantReasonCardinality = min(
                max(1, maximumVariantReasonCardinality),
                64
            )
        }
    }

    public struct LatencyDistribution: Equatable, Sendable {
        public let upperBounds: [TimeInterval]
        /// Non-cumulative bucket counts. The final bucket is positive infinity.
        public let bucketCounts: [UInt64]
        public let count: UInt64
        public let sum: TimeInterval
        public let minimum: TimeInterval?
        public let maximum: TimeInterval?

        public init(
            upperBounds: [TimeInterval],
            bucketCounts: [UInt64],
            count: UInt64,
            sum: TimeInterval,
            minimum: TimeInterval?,
            maximum: TimeInterval?
        ) {
            self.upperBounds = upperBounds
            self.bucketCounts = bucketCounts
            self.count = count
            self.sum = sum
            self.minimum = minimum
            self.maximum = maximum
        }

        public var average: TimeInterval? {
            count > 0 ? sum / Double(count) : nil
        }

        public func approximateQuantile(_ quantile: Double) -> TimeInterval? {
            guard count > 0, quantile.isFinite else { return nil }
            let normalized = min(max(quantile, 0), 1)
            let rank = max(UInt64(1), UInt64(ceil(normalized * Double(count))))
            var cumulative: UInt64 = 0
            for (index, bucketCount) in bucketCounts.enumerated() {
                cumulative &+= bucketCount
                guard cumulative >= rank else { continue }
                if index < upperBounds.count {
                    return upperBounds[index]
                }
                return maximum
            }
            return maximum
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public static let empty = Snapshot(
            segmentFetchLatency: .init(
                upperBounds: Configuration.defaultLatencyUpperBounds,
                bucketCounts: Array(
                    repeating: 0,
                    count: Configuration.defaultLatencyUpperBounds.count + 1
                ),
                count: 0,
                sum: 0,
                minimum: nil,
                maximum: nil
            ),
            fetchErrorCounts: [:],
            retryOutcomeCounts: [:],
            cacheHitCount: 0,
            cacheMissCount: 0,
            memoryCacheHitCount: 0,
            diskCacheHitCount: 0,
            liveEdgeDistanceSeconds: nil,
            variantSwitchReasonCounts: [:],
            latestVariantSwitchReason: nil,
            originByteCount: 0,
            originRetryCount: 0,
            schedulerScheduledCount: 0,
            schedulerReadyCount: 0,
            schedulerFailureCount: 0,
            schedulerReadyPartCount: 0
        )

        public let segmentFetchLatency: LatencyDistribution
        public let fetchErrorCounts: [HLSSegmentFetcher.FetchErrorCategory: UInt64]
        public let retryOutcomeCounts: [HLSSegmentFetcher.RetryOutcome: UInt64]
        public let cacheHitCount: Int
        public let cacheMissCount: Int
        public let memoryCacheHitCount: Int
        public let diskCacheHitCount: Int
        public let liveEdgeDistanceSeconds: TimeInterval?
        public let variantSwitchReasonCounts: [String: UInt64]
        public let latestVariantSwitchReason: String?
        public let originByteCount: Int
        public let originRetryCount: Int
        public let schedulerScheduledCount: Int
        public let schedulerReadyCount: Int
        public let schedulerFailureCount: Int
        public let schedulerReadyPartCount: Int

        public init(
            segmentFetchLatency: LatencyDistribution,
            fetchErrorCounts: [HLSSegmentFetcher.FetchErrorCategory: UInt64],
            retryOutcomeCounts: [HLSSegmentFetcher.RetryOutcome: UInt64],
            cacheHitCount: Int,
            cacheMissCount: Int,
            memoryCacheHitCount: Int = 0,
            diskCacheHitCount: Int = 0,
            liveEdgeDistanceSeconds: TimeInterval?,
            variantSwitchReasonCounts: [String: UInt64],
            latestVariantSwitchReason: String?,
            originByteCount: Int = 0,
            originRetryCount: Int = 0,
            schedulerScheduledCount: Int = 0,
            schedulerReadyCount: Int = 0,
            schedulerFailureCount: Int = 0,
            schedulerReadyPartCount: Int = 0
        ) {
            self.segmentFetchLatency = segmentFetchLatency
            self.fetchErrorCounts = fetchErrorCounts
            self.retryOutcomeCounts = retryOutcomeCounts
            self.cacheHitCount = max(0, cacheHitCount)
            self.cacheMissCount = max(0, cacheMissCount)
            self.memoryCacheHitCount = max(0, memoryCacheHitCount)
            self.diskCacheHitCount = max(0, diskCacheHitCount)
            self.liveEdgeDistanceSeconds = liveEdgeDistanceSeconds
            self.variantSwitchReasonCounts = variantSwitchReasonCounts
            self.latestVariantSwitchReason = latestVariantSwitchReason
            self.originByteCount = max(0, originByteCount)
            self.originRetryCount = max(0, originRetryCount)
            self.schedulerScheduledCount = max(0, schedulerScheduledCount)
            self.schedulerReadyCount = max(0, schedulerReadyCount)
            self.schedulerFailureCount = max(0, schedulerFailureCount)
            self.schedulerReadyPartCount = max(0, schedulerReadyPartCount)
        }

        public var cacheHitRatio: Double? {
            let total = Double(cacheHitCount) + Double(cacheMissCount)
            return total > 0 ? Double(cacheHitCount) / total : nil
        }
    }

    private struct MutableLatencyDistribution {
        let upperBounds: [TimeInterval]
        var bucketCounts: [UInt64]
        var count: UInt64 = 0
        var sum: TimeInterval = 0
        var minimum: TimeInterval?
        var maximum: TimeInterval?

        init(upperBounds: [TimeInterval]) {
            self.upperBounds = upperBounds
            self.bucketCounts = Array(repeating: 0, count: upperBounds.count + 1)
        }

        mutating func record(_ value: TimeInterval) {
            let normalized = value.isFinite ? max(0, value) : 0
            let bucket = upperBounds.firstIndex(where: { normalized <= $0 })
                ?? upperBounds.count
            bucketCounts[bucket] &+= 1
            count &+= 1
            sum += normalized
            minimum = minimum.map { min($0, normalized) } ?? normalized
            maximum = maximum.map { max($0, normalized) } ?? normalized
        }

        var snapshot: LatencyDistribution {
            LatencyDistribution(
                upperBounds: upperBounds,
                bucketCounts: bucketCounts,
                count: count,
                sum: sum,
                minimum: minimum,
                maximum: maximum
            )
        }
    }

    private let configuration: Configuration
    private var latency: MutableLatencyDistribution
    private var fetchErrorCounts: [HLSSegmentFetcher.FetchErrorCategory: UInt64] = [:]
    private var retryOutcomeCounts: [HLSSegmentFetcher.RetryOutcome: UInt64] = [:]
    private var cacheHitCount = 0
    private var cacheMissCount = 0
    private var memoryCacheHitCount = 0
    private var diskCacheHitCount = 0
    private var liveEdgeDistanceSeconds: TimeInterval?
    private var variantSwitchReasonCounts: [String: UInt64] = [:]
    private var latestVariantSwitchReason: String?
    private var originByteCount = 0
    private var originRetryCount = 0
    private var schedulerScheduledCount = 0
    private var schedulerReadyCount = 0
    private var schedulerFailureCount = 0
    private var schedulerReadyPartCount = 0
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.latency = MutableLatencyDistribution(
            upperBounds: configuration.latencyUpperBounds
        )
    }

    public func recordFetch(_ event: HLSSegmentFetcher.FetchEvent) {
        latency.record(event.duration)
        originByteCount = Self.saturatingAdd(originByteCount, event.byteCount)
        originRetryCount = Self.saturatingAdd(originRetryCount, event.retryCount)
        retryOutcomeCounts[event.retryOutcome, default: 0] &+= 1
        if let errorCategory = event.errorCategory {
            fetchErrorCounts[errorCategory, default: 0] &+= 1
        }
        publish()
    }

    public func updateSchedulerTelemetry(
        scheduledCount: Int,
        readyCount: Int,
        failureCount: Int,
        readyPartCount: Int
    ) {
        let scheduled = max(0, scheduledCount)
        let ready = max(0, readyCount)
        let failures = max(0, failureCount)
        let readyParts = max(0, readyPartCount)
        guard schedulerScheduledCount != scheduled
                || schedulerReadyCount != ready
                || schedulerFailureCount != failures
                || schedulerReadyPartCount != readyParts
        else {
            return
        }
        schedulerScheduledCount = scheduled
        schedulerReadyCount = ready
        schedulerFailureCount = failures
        schedulerReadyPartCount = readyParts
        publish()
    }

    public func updateCacheMetrics(_ metrics: HLSSegmentCache.Metrics) {
        guard cacheHitCount != metrics.hitCount
                || cacheMissCount != metrics.missCount
                || memoryCacheHitCount != metrics.memoryHitCount
                || diskCacheHitCount != metrics.diskHitCount
        else {
            return
        }
        cacheHitCount = metrics.hitCount
        cacheMissCount = metrics.missCount
        memoryCacheHitCount = metrics.memoryHitCount
        diskCacheHitCount = metrics.diskHitCount
        publish()
    }

    public func updateLiveEdgeDistance(_ distance: TimeInterval?) {
        let normalized: TimeInterval?
        if let distance, distance.isFinite {
            normalized = max(0, distance)
        } else {
            normalized = nil
        }
        guard liveEdgeDistanceSeconds != normalized else { return }
        liveEdgeDistanceSeconds = normalized
        publish()
    }

    public func recordVariantSwitch(reason: String) {
        let normalized = reason.isEmpty ? "unknown" : reason
        let key: String
        if variantSwitchReasonCounts[normalized] != nil
            || variantSwitchReasonCounts.count < configuration.maximumVariantReasonCardinality {
            key = normalized
        } else {
            key = "other"
        }
        variantSwitchReasonCounts[key, default: 0] &+= 1
        latestVariantSwitchReason = key
        publish()
    }

    public func snapshot() -> Snapshot {
        makeSnapshot()
    }

    /// Ordered telemetry snapshots with a single-element backpressure buffer.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func reset() {
        latency = MutableLatencyDistribution(upperBounds: configuration.latencyUpperBounds)
        fetchErrorCounts.removeAll(keepingCapacity: true)
        retryOutcomeCounts.removeAll(keepingCapacity: true)
        cacheHitCount = 0
        cacheMissCount = 0
        memoryCacheHitCount = 0
        diskCacheHitCount = 0
        liveEdgeDistanceSeconds = nil
        variantSwitchReasonCounts.removeAll(keepingCapacity: true)
        latestVariantSwitchReason = nil
        originByteCount = 0
        originRetryCount = 0
        schedulerScheduledCount = 0
        schedulerReadyCount = 0
        schedulerFailureCount = 0
        schedulerReadyPartCount = 0
        publish()
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            segmentFetchLatency: latency.snapshot,
            fetchErrorCounts: fetchErrorCounts,
            retryOutcomeCounts: retryOutcomeCounts,
            cacheHitCount: cacheHitCount,
            cacheMissCount: cacheMissCount,
            memoryCacheHitCount: memoryCacheHitCount,
            diskCacheHitCount: diskCacheHitCount,
            liveEdgeDistanceSeconds: liveEdgeDistanceSeconds,
            variantSwitchReasonCounts: variantSwitchReasonCounts,
            latestVariantSwitchReason: latestVariantSwitchReason,
            originByteCount: originByteCount,
            originRetryCount: originRetryCount,
            schedulerScheduledCount: schedulerScheduledCount,
            schedulerReadyCount: schedulerReadyCount,
            schedulerFailureCount: schedulerFailureCount,
            schedulerReadyPartCount: schedulerReadyPartCount
        )
    }

    private func publish() {
        let value = makeSnapshot()
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let value = lhs.addingReportingOverflow(max(0, rhs))
        return value.overflow ? .max : value.partialValue
    }
}
