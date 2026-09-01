import Foundation

/// Stable scenario identifiers required by the production feed qualification.
public enum HLSFeedQualificationScenarioID: String, CaseIterable, Codable, Sendable {
    case coldLaunchWithoutCache = "cold_launch_without_cache"
    case coldLaunchWithWarmDisk = "cold_launch_with_warm_disk"
    case revisit
    case forwardBackwardPaging = "forward_backward_paging"
    case rapidFling = "rapid_fling"
    case directionReversal = "direction_reversal"
    case memoryPressure = "memory_pressure"
    case cacheEviction = "cache_eviction"
    case backgroundForeground = "background_foreground"
    case offlineWarmReuse = "offline_warm_reuse"
    case uncachedOfflineFailure = "uncached_offline_failure"
    case poorNetworkRecovery = "poor_network_recovery"
    case transientFailureRecovery = "transient_failure_recovery"
}

/// One bounded, sanitized outcome in a feed qualification run.
public struct HLSFeedQualificationScenarioResult: Codable, Equatable, Sendable {
    public let id: HLSFeedQualificationScenarioID
    public let passed: Bool
    public let observationCount: Int

    public init(
        id: HLSFeedQualificationScenarioID,
        passed: Bool,
        observationCount: Int = 1
    ) {
        self.id = id
        self.passed = passed
        self.observationCount = max(0, observationCount)
    }
}

/// One schema-versioned release report for feed navigation, networking, cache,
/// playback handoff, and bounded resource ownership.
///
/// The report contains no item IDs, URLs, headers, or user identifiers. Callers
/// generate it after the engine has settled (and, for leak accounting, after
/// stopping the engine) from fixed-cardinality telemetry plus scenario results.
public struct HLSFeedQualificationReport: Codable, Equatable, Sendable {
    public struct Distribution: Codable, Equatable, Sendable {
        public let count: UInt64
        public let totalMilliseconds: Double
        public let p50Milliseconds: Double?
        public let p95Milliseconds: Double?
        public let maximumMilliseconds: Double?
    }

    public struct EvictionCount: Codable, Equatable, Sendable {
        public let reason: HLSFeedTelemetry.CacheEvictionReason
        public let count: UInt64
    }

    public struct Metrics: Codable, Equatable, Sendable {
        public let firstFrameLatency: Distribution
        public let cancellationLatency: Distribution
        public let stallDuration: Distribution
        public let handoffAttemptCount: UInt64
        public let handoffReadyCount: UInt64
        public let handoffSuccessCount: UInt64
        public let cacheHitRequestCount: UInt64
        public let cacheMissRequestCount: UInt64
        public let cacheHitBytes: UInt64
        public let originRequestCount: UInt64
        public let originByteCount: UInt64
        public let currentMemoryBytes: Int
        public let peakMemoryBytes: Int
        public let memoryByteLimit: Int
        public let currentDiskBytes: Int
        public let peakDiskBytes: Int
        public let diskByteLimit: Int
        public let memoryEntryCount: Int
        public let diskEntryCount: Int
        public let evictionCounts: [EvictionCount]
        public let maximumPlayerPoolOccupancy: Int
        public let maximumProxyPoolOccupancy: Int
        public let playerPoolLimit: Int
        public let maximumAudiblePlaybackCount: Int
        public let staleCompletionCount: Int
        public let staleFocusedPlaybackCount: Int
        public let resourceLeakCount: Int
        public let finalAllocatedPlayerCount: Int
        public let finalActiveLoadCount: Int
    }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let passed: Bool
    public let failureCodes: [String]
    public let scenarios: [HLSFeedQualificationScenarioResult]
    public let metrics: Metrics

    public init(
        scenarios: [HLSFeedQualificationScenarioResult],
        telemetry: HLSFeedTelemetry.Snapshot,
        engine: HLSFeedEngineSnapshot,
        policy: FeedPlaybackPolicy,
        staleFocusedPlaybackCount: Int = 0,
        resourceLeakCount: Int = 0
    ) {
        let orderedScenarios = scenarios.sorted { $0.id.rawValue < $1.id.rawValue }
        let paths = telemetry.paths
        let resources = telemetry.resources
        let normalizedStaleFocus = max(0, staleFocusedPlaybackCount)
        let normalizedLeaks = max(0, resourceLeakCount)
        let evictionCounts = resources.evictionCounts
            .map { EvictionCount(reason: $0.key, count: $0.value) }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }

        self.schemaVersion = Self.currentSchemaVersion
        self.scenarios = orderedScenarios
        self.metrics = Metrics(
            firstFrameLatency: Self.summary(paths.map(\.firstFrameLatency)),
            cancellationLatency: Self.summary(paths.map(\.cancellationLatency)),
            stallDuration: Self.summary(paths.map(\.stallDuration)),
            handoffAttemptCount: Self.sum(paths.map(\.handoffAttemptCount)),
            handoffReadyCount: Self.sum(paths.map(\.handoffReadyCount)),
            handoffSuccessCount: Self.sum(paths.map(\.handoffSuccessCount)),
            cacheHitRequestCount: Self.sum(paths.map(\.cacheHitCount)),
            cacheMissRequestCount: Self.sum(paths.map(\.cacheMissCount)),
            cacheHitBytes: Self.sum(paths.map(\.originBytesAvoided)),
            originRequestCount: Self.sum(paths.map(\.originRequestCount)),
            originByteCount: Self.sum(paths.map(\.originBytesFetched)),
            currentMemoryBytes: resources.memoryResidentBytes,
            peakMemoryBytes: resources.maximumMemoryResidentBytes,
            memoryByteLimit: policy.budget.memoryCacheBytes,
            currentDiskBytes: resources.diskResidentBytes,
            peakDiskBytes: resources.maximumDiskResidentBytes,
            diskByteLimit: policy.budget.diskCacheBytes,
            memoryEntryCount: resources.memoryEntryCount,
            diskEntryCount: resources.diskEntryCount,
            evictionCounts: evictionCounts,
            maximumPlayerPoolOccupancy: engine.maximumObservedPoolOccupancy,
            maximumProxyPoolOccupancy: resources.maximumProxyPoolOccupancy,
            playerPoolLimit: policy.concurrency.maximumPlayerCount,
            maximumAudiblePlaybackCount: engine.maximumObservedAudiblePlaybackCount,
            staleCompletionCount: engine.staleCompletionCount,
            staleFocusedPlaybackCount: normalizedStaleFocus,
            resourceLeakCount: normalizedLeaks,
            finalAllocatedPlayerCount: engine.allocatedPlayerCount,
            finalActiveLoadCount: engine.activeLoadCount
        )

        var failures: [String] = []
        let resultsByID = Dictionary(orderedScenarios.map { ($0.id, $0) }, uniquingKeysWith: {
            first, _ in first
        })
        for id in HLSFeedQualificationScenarioID.allCases {
            guard let result = resultsByID[id] else {
                failures.append("missing_scenario:\(id.rawValue)")
                continue
            }
            if !result.passed {
                failures.append("failed_scenario:\(id.rawValue)")
            }
        }
        if orderedScenarios.count != resultsByID.count {
            failures.append("duplicate_scenario")
        }
        if metrics.peakMemoryBytes > metrics.memoryByteLimit {
            failures.append("memory_budget_exceeded")
        }
        if metrics.peakDiskBytes > metrics.diskByteLimit {
            failures.append("disk_budget_exceeded")
        }
        if metrics.maximumPlayerPoolOccupancy > metrics.playerPoolLimit
            || metrics.maximumProxyPoolOccupancy > metrics.playerPoolLimit {
            failures.append("player_pool_exceeded")
        }
        if metrics.maximumAudiblePlaybackCount > 1 {
            failures.append("multiple_audible_players")
        }
        if metrics.staleCompletionCount > 0 || normalizedStaleFocus > 0 {
            failures.append("stale_playback_observed")
        }
        if normalizedLeaks > 0 || engine.activeLoadCount > 0 {
            failures.append("resource_leak_observed")
        }
        self.failureCodes = failures.sorted()
        self.passed = failures.isEmpty
    }

    public func machineReadableData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func summary(
        _ distributions: [HLSFeedTelemetry.Distribution]
    ) -> Distribution {
        let first = distributions.first
        let bounds = first?.upperBounds ?? []
        var buckets = Array(repeating: UInt64(0), count: bounds.count + 1)
        var count: UInt64 = 0
        var total: TimeInterval = 0
        var maximum: TimeInterval?
        for distribution in distributions where distribution.upperBounds == bounds {
            count = add(count, distribution.count)
            total += distribution.sum
            if !total.isFinite { total = .greatestFiniteMagnitude }
            maximum = [maximum, distribution.maximum].compactMap { $0 }.max()
            for index in buckets.indices where index < distribution.bucketCounts.count {
                buckets[index] = add(buckets[index], distribution.bucketCounts[index])
            }
        }
        func quantile(_ value: Double) -> TimeInterval? {
            guard count > 0 else { return nil }
            let rank = max(UInt64(1), UInt64(ceil(value * Double(count))))
            var cumulative: UInt64 = 0
            for (index, bucketCount) in buckets.enumerated() {
                cumulative = add(cumulative, bucketCount)
                if cumulative >= rank {
                    let bucketEstimate = index < bounds.count ? bounds[index] : maximum
                    guard let bucketEstimate else { return nil }
                    return maximum.map { min(bucketEstimate, $0) } ?? bucketEstimate
                }
            }
            return maximum
        }
        return Distribution(
            count: count,
            totalMilliseconds: total * 1_000,
            p50Milliseconds: quantile(0.5).map { $0 * 1_000 },
            p95Milliseconds: quantile(0.95).map { $0 * 1_000 },
            maximumMilliseconds: maximum.map { $0 * 1_000 }
        )
    }

    private static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0, add)
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
