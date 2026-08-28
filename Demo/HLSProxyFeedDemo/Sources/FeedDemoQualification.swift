import Foundation
import ProxyPlayerKit

struct FeedDemoQualificationReport: Codable, Equatable, Sendable {
    let passed: Bool
    let failures: [String]
    let navigationCount: Int
    let measuredNavigationCount: Int
    let finalRequestedItemID: String?
    let finalActiveItemID: String?
    let finalPlaybackStarted: Bool
    let firstFrameCount: UInt64
    let warmFirstFrameCount: UInt64
    let warmFirstFrameP95Milliseconds: Double?
    let cancellationCount: UInt64
    let cancellationMaximumMilliseconds: Double?
    let handoffAttemptCount: UInt64
    let handoffSuccessCount: UInt64
    let handoffSuccessRate: Double?
    let managedMemoryGrowthBytes: Int
    let managedMemoryMaximumBytes: Int
    let managedDiskMaximumBytes: Int
    let maximumPlayerPoolOccupancy: Int
    let maximumProxyPoolOccupancy: Int
    let maximumPlayerPoolLimit: Int
    let finalAllocatedPlayerCount: Int
    let finalActiveLoadCount: Int
    let staleCompletionCount: Int

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func make(
        navigationCount: Int,
        measuredNavigationCount: Int,
        requestedItemID: FeedItemID?,
        snapshot: HLSFeedEngineSnapshot,
        telemetry: HLSFeedTelemetry.Snapshot,
        policy: FeedPlaybackPolicy,
        warmupMemoryBytes: Int?
    ) -> Self {
        let warmFirstFramePaths = telemetry.paths.filter {
            $0.path.reuse == .warm && $0.path.intent == .focused
        }
        let warmFirstFrameCount = warmFirstFramePaths.reduce(UInt64(0)) {
            $0 &+ $1.firstFrameLatency.count
        }
        let warmFirstFrameP95 = warmFirstFramePaths.compactMap {
            $0.firstFrameLatency.approximateQuantile(0.95)
        }.max()
        let cancellationMaximum = telemetry.paths.compactMap {
            $0.cancellationLatency.maximum
        }.max()
        let handoffAttemptCount = telemetry.paths.reduce(UInt64(0)) {
            $0 &+ $1.handoffAttemptCount
        }
        let handoffSuccessCount = telemetry.handoffSuccessCount
        let handoffSuccessRate = handoffAttemptCount == 0
            ? nil
            : Double(handoffSuccessCount) / Double(handoffAttemptCount)
        let focusedPlayback = requestedItemID.flatMap { snapshot.playback(for: $0) }
        let memoryGrowth = max(
            0,
            telemetry.resources.memoryResidentBytes - (warmupMemoryBytes ?? 0)
        )

        var failures: [String] = []
        if measuredNavigationCount < 100 {
            failures.append("fewer than 100 measured rapid navigations")
        }
        if snapshot.activeItemID != requestedItemID {
            failures.append("the active item does not match the final requested item")
        }
        if focusedPlayback?.hasStartedPlayback != true {
            failures.append("the final focused AVPlayer did not enter platform playback")
        }
        if snapshot.activeLoadCount != 0 {
            failures.append("player loads did not drain")
        }
        if !snapshot.failures.isEmpty {
            failures.append("the engine reported playback failures")
        }
        if snapshot.maximumObservedPoolOccupancy > policy.concurrency.maximumPlayerCount {
            failures.append("the player pool exceeded its configured bound")
        }
        if telemetry.resources.maximumProxyPoolOccupancy > policy.concurrency.maximumPlayerCount {
            failures.append("the allocated proxy-player pool exceeded its configured bound")
        }
        if telemetry.resources.maximumMemoryResidentBytes > policy.budget.memoryCacheBytes {
            failures.append("the memory cache exceeded its configured bound")
        }
        if telemetry.resources.maximumDiskResidentBytes > policy.budget.diskCacheBytes {
            failures.append("the disk cache exceeded its configured bound")
        }
        if warmFirstFrameCount == 0 {
            failures.append("no predicted-warm first-frame samples were recorded")
        } else if let warmFirstFrameP95, warmFirstFrameP95 > 0.5 {
            failures.append("predicted-warm visible first-frame p95 exceeded 500 ms")
        }
        if let cancellationMaximum, cancellationMaximum > 0.25 {
            failures.append("obsolete work took longer than 250 ms to drain")
        }
        if handoffAttemptCount == 0 {
            failures.append("no ready handoff attempts were recorded")
        } else if let handoffSuccessRate, handoffSuccessRate < 0.99 {
            failures.append("successful ready handoffs fell below 99 percent")
        }
        if warmupMemoryBytes == nil {
            failures.append("the post-warmup memory baseline was not captured")
        } else if memoryGrowth > 1_048_576 {
            failures.append("managed memory grew by more than 1 MiB per 100 navigations")
        }

        return Self(
            passed: failures.isEmpty,
            failures: failures,
            navigationCount: navigationCount,
            measuredNavigationCount: measuredNavigationCount,
            finalRequestedItemID: requestedItemID?.rawValue,
            finalActiveItemID: snapshot.activeItemID?.rawValue,
            finalPlaybackStarted: focusedPlayback?.hasStartedPlayback == true,
            firstFrameCount: telemetry.firstFrameCount,
            warmFirstFrameCount: warmFirstFrameCount,
            warmFirstFrameP95Milliseconds: warmFirstFrameP95.map { $0 * 1_000 },
            cancellationCount: telemetry.cancellationCount,
            cancellationMaximumMilliseconds: cancellationMaximum.map { $0 * 1_000 },
            handoffAttemptCount: handoffAttemptCount,
            handoffSuccessCount: handoffSuccessCount,
            handoffSuccessRate: handoffSuccessRate,
            managedMemoryGrowthBytes: memoryGrowth,
            managedMemoryMaximumBytes: telemetry.resources.maximumMemoryResidentBytes,
            managedDiskMaximumBytes: telemetry.resources.maximumDiskResidentBytes,
            maximumPlayerPoolOccupancy: snapshot.maximumObservedPoolOccupancy,
            maximumProxyPoolOccupancy: telemetry.resources.maximumProxyPoolOccupancy,
            maximumPlayerPoolLimit: policy.concurrency.maximumPlayerCount,
            finalAllocatedPlayerCount: snapshot.allocatedPlayerCount,
            finalActiveLoadCount: snapshot.activeLoadCount,
            staleCompletionCount: snapshot.staleCompletionCount
        )
    }
}

enum FeedDemoQualificationNetworkCondition: String, Codable, Equatable, Sendable {
    case normal
    case poor
    case offline
}

/// Fixed-cardinality evidence emitted by the real, vertically paged SwiftUI
/// qualification. It intentionally retains no URLs, headers, request paths, or
/// item identifiers; XCUITest proves the exact page IDs through accessibility.
struct FeedDemoVerticalQualificationReport: Codable, Equatable, Sendable {
    struct Distribution: Codable, Equatable, Sendable {
        let count: UInt64
        let totalMilliseconds: Double
        let p95Milliseconds: Double?
        let maximumMilliseconds: Double?
    }

    struct EvictionCount: Codable, Equatable, Sendable {
        let reason: HLSFeedTelemetry.CacheEvictionReason
        let count: UInt64
    }

    static let currentSchemaVersion = 1
    static let qualificationKind = "vertical_paging_ui"
    static let scenarioIDs = [
        "controlled_single_page",
        "forward_backward_revisit",
        "rapid_fling",
        "direction_reversal",
        "poor_network_recovery",
        "offline_cached_reuse",
        "memory_pressure",
        "background_foreground",
    ]

    let schemaVersion: Int
    let qualificationKind: String
    let passed: Bool
    let failureCodes: [String]
    let scenarioIDs: [String]

    let finalOwnershipAligned: Bool
    let finalPlaybackStarted: Bool
    let firstFrameLatency: Distribution
    let cancellationLatency: Distribution
    let stallDuration: Distribution
    let handoffAttemptCount: UInt64
    let handoffReadyCount: UInt64
    let handoffSuccessCount: UInt64
    let cacheHitRequestCount: UInt64
    let cacheMissRequestCount: UInt64
    let cacheHitBytes: UInt64
    let originRequestCount: UInt64
    let originByteCount: UInt64
    let fixtureRequestCount: Int
    let fixtureResponseByteCount: Int
    let fixtureOfflineRequestCount: Int
    let fixtureMaximumActiveRequestCount: Int
    let currentMemoryBytes: Int
    let peakMemoryBytes: Int
    let memoryByteLimit: Int
    let currentDiskBytes: Int
    let peakDiskBytes: Int
    let diskByteLimit: Int
    let evictionCounts: [EvictionCount]
    let maximumPlayerPoolOccupancy: Int
    let maximumProxyPoolOccupancy: Int
    let playerPoolLimit: Int
    let maximumAudiblePlaybackCount: Int
    let finalActiveLoadCount: Int
    let staleCompletionCount: Int
    let networkConditionTransitionCount: Int
    let memoryPressureActionCount: Int
    let backgroundTransitionCount: Int
    let foregroundTransitionCount: Int

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func make(
        focusedItemID: FeedItemID?,
        engine: HLSFeedEngineSnapshot,
        telemetry: HLSFeedTelemetry.Snapshot,
        origin: FeedDemoFixtureOrigin.Snapshot,
        policy: FeedPlaybackPolicy,
        networkConditionTransitionCount: Int,
        memoryPressureActionCount: Int,
        backgroundTransitionCount: Int,
        foregroundTransitionCount: Int
    ) -> Self {
        let firstFrame = summary(telemetry.paths.map(\.firstFrameLatency))
        let cancellation = summary(telemetry.paths.map(\.cancellationLatency))
        let stall = summary(telemetry.paths.map(\.stallDuration))
        let handoffAttemptCount = sum(telemetry.paths.map(\.handoffAttemptCount))
        let handoffReadyCount = sum(telemetry.paths.map(\.handoffReadyCount))
        let handoffSuccessCount = sum(telemetry.paths.map(\.handoffSuccessCount))
        let cacheHitCount = sum(telemetry.paths.map(\.cacheHitCount))
        let cacheMissCount = sum(telemetry.paths.map(\.cacheMissCount))
        let cacheHitBytes = sum(telemetry.paths.map(\.originBytesAvoided))
        let originRequestCount = sum(telemetry.paths.map(\.originRequestCount))
        let originByteCount = sum(telemetry.paths.map(\.originBytesFetched))
        let finalPlayback = focusedItemID.flatMap { engine.playback(for: $0) }
        let ownershipAligned = focusedItemID != nil
            && engine.activeItemID == focusedItemID
            && engine.audibleItemID == focusedItemID
        let evictionCounts = HLSFeedTelemetry.CacheEvictionReason.allCases.map {
            EvictionCount(
                reason: $0,
                count: telemetry.resources.evictionCounts[$0, default: 0]
            )
        }

        var failures: [String] = []
        if !ownershipAligned { failures.append("final_ownership_mismatch") }
        if finalPlayback?.hasStartedPlayback != true {
            failures.append("final_playback_not_started")
        }
        if !engine.failures.isEmpty { failures.append("engine_failure") }
        if firstFrame.count == 0 { failures.append("missing_first_frame_metric") }
        if cancellation.count == 0 { failures.append("missing_cancellation_metric") }
        if let maximum = cancellation.maximumMilliseconds, maximum > 250 {
            failures.append("cancellation_deadline_exceeded")
        }
        if handoffAttemptCount == 0 || handoffSuccessCount == 0 {
            failures.append("missing_handoff_metric")
        }
        if cacheHitCount + cacheMissCount == 0 {
            failures.append("missing_cache_metric")
        }
        if origin.requestCount == 0 || origin.responseByteCount == 0 {
            failures.append("missing_network_metric")
        }
        if telemetry.resources.maximumMemoryResidentBytes > policy.budget.memoryCacheBytes {
            failures.append("memory_budget_exceeded")
        }
        if telemetry.resources.maximumDiskResidentBytes > policy.budget.diskCacheBytes {
            failures.append("disk_budget_exceeded")
        }
        if engine.maximumObservedPoolOccupancy > policy.concurrency.maximumPlayerCount
            || telemetry.resources.maximumProxyPoolOccupancy
                > policy.concurrency.maximumPlayerCount {
            failures.append("player_pool_exceeded")
        }
        if engine.maximumObservedAudiblePlaybackCount > 1 {
            failures.append("multiple_audible_players")
        }
        if engine.activeLoadCount != 0 || origin.activeRequestCount != 0 {
            failures.append("resource_work_not_drained")
        }
        if networkConditionTransitionCount < 3 {
            failures.append("network_conditions_not_exercised")
        }
        if memoryPressureActionCount < 1 {
            failures.append("memory_pressure_not_exercised")
        }
        if backgroundTransitionCount < 1 || foregroundTransitionCount < 1 {
            failures.append("lifecycle_not_exercised")
        }

        return Self(
            schemaVersion: currentSchemaVersion,
            qualificationKind: qualificationKind,
            passed: failures.isEmpty,
            failureCodes: failures.sorted(),
            scenarioIDs: scenarioIDs,
            finalOwnershipAligned: ownershipAligned,
            finalPlaybackStarted: finalPlayback?.hasStartedPlayback == true,
            firstFrameLatency: firstFrame,
            cancellationLatency: cancellation,
            stallDuration: stall,
            handoffAttemptCount: handoffAttemptCount,
            handoffReadyCount: handoffReadyCount,
            handoffSuccessCount: handoffSuccessCount,
            cacheHitRequestCount: cacheHitCount,
            cacheMissRequestCount: cacheMissCount,
            cacheHitBytes: cacheHitBytes,
            originRequestCount: originRequestCount,
            originByteCount: originByteCount,
            fixtureRequestCount: origin.requestCount,
            fixtureResponseByteCount: origin.responseByteCount,
            fixtureOfflineRequestCount: origin.offlineRequestCount,
            fixtureMaximumActiveRequestCount: origin.maximumActiveRequestCount,
            currentMemoryBytes: telemetry.resources.memoryResidentBytes,
            peakMemoryBytes: telemetry.resources.maximumMemoryResidentBytes,
            memoryByteLimit: policy.budget.memoryCacheBytes,
            currentDiskBytes: telemetry.resources.diskResidentBytes,
            peakDiskBytes: telemetry.resources.maximumDiskResidentBytes,
            diskByteLimit: policy.budget.diskCacheBytes,
            evictionCounts: evictionCounts,
            maximumPlayerPoolOccupancy: engine.maximumObservedPoolOccupancy,
            maximumProxyPoolOccupancy: telemetry.resources.maximumProxyPoolOccupancy,
            playerPoolLimit: policy.concurrency.maximumPlayerCount,
            maximumAudiblePlaybackCount: engine.maximumObservedAudiblePlaybackCount,
            finalActiveLoadCount: engine.activeLoadCount,
            staleCompletionCount: engine.staleCompletionCount,
            networkConditionTransitionCount: networkConditionTransitionCount,
            memoryPressureActionCount: memoryPressureActionCount,
            backgroundTransitionCount: backgroundTransitionCount,
            foregroundTransitionCount: foregroundTransitionCount
        )
    }

    private static func summary(
        _ distributions: [HLSFeedTelemetry.Distribution]
    ) -> Distribution {
        let bounds = distributions.first?.upperBounds ?? []
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
        let p95: TimeInterval? = {
            guard count > 0 else { return nil }
            let rank = max(UInt64(1), UInt64(ceil(0.95 * Double(count))))
            var cumulative: UInt64 = 0
            for (index, bucketCount) in buckets.enumerated() {
                cumulative = add(cumulative, bucketCount)
                if cumulative >= rank {
                    return index < bounds.count ? bounds[index] : maximum
                }
            }
            return maximum
        }()
        return Distribution(
            count: count,
            totalMilliseconds: total * 1_000,
            p95Milliseconds: p95.map { $0 * 1_000 },
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
