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
