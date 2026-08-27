#if canImport(Network)
import Foundation
import XCTest
@testable import HLSCore
@testable import ProxyPlayerKit

final class HLSFeedQualificationTests: XCTestCase {
    private struct ReadinessReport: Codable {
        let transitionCount: Int
        let coldReadinessMilliseconds: Double
        let warmReadinessP95Milliseconds: Double
        let preparationCacheReuseCount: Int
        let revisitCount: Int
        let revisitCacheHitCount: Int
        let revisitCacheHitRate: Double
        let maximumActivePreparations: Int
        let maximumConcurrentPreparationLimit: Int
        let maximumResidentItems: Int
        let residentItemLimit: Int
        let maximumResidentEstimatedBytes: Int
        let residentEstimatedByteLimit: Int
        let memoryBytes: Int
        let memoryByteLimit: Int
        let diskBytes: Int
        let diskByteLimit: Int
    }

    private struct SourceCoverageReport: Codable {
        let sourceTypes: [String]
        let vodResources: Int
        let liveResources: Int
        let stitchedResources: Int
        let stitchedPlaylistCount: Int
        let liveMediaSequenceLowerBound: Int
        let liveMediaSequenceUpperBound: Int
    }

    func testLocalOriginReadinessAndReuseMeetFeedReleaseThresholds() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }

        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.maximumLeadingSegments = 1
        policy.eviction.usesDiskCache = false
        policy.eviction.offscreenGracePeriod = 0
        policy.budget.diskCacheBytes = 0
        policy = try policy.validated()
        let backend = try HLSFeedPreparationBackend(
            policy: policy,
            allowsInsecureManifests: true
        )
        let items = (0..<14).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "qualification-\(index)"),
                source: .stream(
                    url: origin.fixturePlaylistURL(
                        named: index.isMultiple(of: 2) ? "short-a" : "short-b"
                    ),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 512 * 1_024
            )
        }
        let coordinator = try FeedCoordinator(items: items, policy: policy, backend: backend)
        let clock = ContinuousClock()
        var readinessSeconds: [TimeInterval] = []
        var maximumResidentItems = 0
        var maximumResidentEstimatedBytes = 0
        var revisitCount = 0
        var revisitCacheHitCount = 0

        for step in 0..<100 {
            let index = step % items.count
            let nextIndex = (index + 1) % items.count
            let afterNextIndex = (index + 2) % items.count
            let signal = FeedViewportSignal(
                generation: .init(rawValue: UInt64(step + 1)),
                focusedItemID: items[index].id,
                visibleItems: [.init(
                    itemID: items[index].id,
                    fraction: 1,
                    distanceInViewports: 0
                )],
                velocityInViewportsPerSecond: 8,
                predictedDestinations: [
                    .init(itemID: items[nextIndex].id, confidence: 0.95),
                    .init(itemID: items[afterNextIndex].id, confidence: 0.7),
                ],
                observedAt: .milliseconds(Int64(step) * 16)
            )
            let originRequestCountBefore = origin.timelineSnapshot().filter {
                $0.kind == .requestStarted
            }.count
            let started = clock.now
            _ = try await coordinator.submit(signal)
            let settled = await coordinator.waitUntilIdle()
            if step >= items.count {
                revisitCount += 1
                let originRequestCountAfter = origin.timelineSnapshot().filter {
                    $0.kind == .requestStarted
                }.count
                if originRequestCountAfter == originRequestCountBefore {
                    revisitCacheHitCount += 1
                }
            }
            readinessSeconds.append(started.duration(to: clock.now).seconds)
            maximumResidentItems = max(maximumResidentItems, settled.entries.count)
            maximumResidentEstimatedBytes = max(
                maximumResidentEstimatedBytes,
                settled.residentEstimatedPreparationBytes
            )
            XCTAssertEqual(settled.generation, signal.generation)
            XCTAssertTrue(settled.readyItemIDs.contains(items[index].id))
            XCTAssertLessThanOrEqual(
                settled.maximumObservedActivePreparations,
                policy.concurrency.maximumConcurrentPreparations
            )
            XCTAssertLessThanOrEqual(settled.entries.count, policy.budget.maximumResidentItems)
            XCTAssertLessThanOrEqual(
                settled.residentEstimatedPreparationBytes,
                policy.budget.maximumEstimatedPreparationBytes
            )
        }

        let settled = await coordinator.waitUntilIdle()
        let cacheMetrics = await backend.cacheMetrics()
        let coldReadiness = try XCTUnwrap(readinessSeconds.first)
        let warmReadinessP95 = try XCTUnwrap(percentile(Array(readinessSeconds.dropFirst()), 0.95))
        let reuseRate = Double(revisitCacheHitCount) / Double(revisitCount)

        XCTAssertLessThanOrEqual(coldReadiness, 0.250)
        XCTAssertLessThanOrEqual(warmReadinessP95, 0.050)
        XCTAssertGreaterThanOrEqual(reuseRate, 0.90)
        XCTAssertEqual(settled.lateCancellationCount, 0)
        XCTAssertLessThanOrEqual(cacheMetrics.totalBytes, policy.budget.memoryCacheBytes)
        XCTAssertLessThanOrEqual(cacheMetrics.diskBytes, policy.budget.diskCacheBytes)

        try QualificationArtifact.write(
            ReadinessReport(
                transitionCount: readinessSeconds.count,
                coldReadinessMilliseconds: coldReadiness * 1_000,
                warmReadinessP95Milliseconds: warmReadinessP95 * 1_000,
                preparationCacheReuseCount: settled.preparationCacheReuseCount,
                revisitCount: revisitCount,
                revisitCacheHitCount: revisitCacheHitCount,
                revisitCacheHitRate: reuseRate,
                maximumActivePreparations: settled.maximumObservedActivePreparations,
                maximumConcurrentPreparationLimit: policy.concurrency.maximumConcurrentPreparations,
                maximumResidentItems: maximumResidentItems,
                residentItemLimit: policy.budget.maximumResidentItems,
                maximumResidentEstimatedBytes: maximumResidentEstimatedBytes,
                residentEstimatedByteLimit: policy.budget.maximumEstimatedPreparationBytes,
                memoryBytes: cacheMetrics.totalBytes,
                memoryByteLimit: policy.budget.memoryCacheBytes,
                diskBytes: cacheMetrics.diskBytes,
                diskByteLimit: policy.budget.diskCacheBytes
            ),
            named: "hls-feed-origin-readiness.json"
        )
        await coordinator.stop()
    }

    func testCheckedInOriginQualifiesVODLiveAndStitchedSources() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.maximumLeadingSegments = 2
        policy.eviction.usesDiskCache = false
        policy.budget.diskCacheBytes = 0
        let backend = try HLSFeedPreparationBackend(
            policy: policy,
            allowsInsecureManifests: true
        )
        let vod = FeedPlaybackItem(
            id: "qualification-vod",
            source: .stream(
                url: origin.fixturePlaylistURL(named: "short-a"),
                kind: .videoOnDemand
            ),
            estimatedPreparationBytes: 512 * 1_024
        )
        let live = FeedPlaybackItem(
            id: "qualification-live",
            source: .stream(
                url: origin.fixturePlaylistURL(named: "live"),
                kind: .live
            ),
            estimatedPreparationBytes: 512 * 1_024
        )
        let signature = HLSClipMediaSignature(
            container: .fragmentedMP4,
            codecs: ["avc1.640028", "mp4a.40.2"],
            tracks: [
                .init(kind: .video, codec: "avc1.640028"),
                .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
            ],
            videoRange: "SDR",
            segmentsAreIndependent: true
        )
        let stitched = FeedPlaybackItem(
            id: "qualification-stitched",
            source: .compatibleClips(["short-a", "short-b"].map { name in
                ProxyPlaybackClip(
                    id: name,
                    playlistURL: origin.fixturePlaylistURL(named: name),
                    mediaSignature: signature
                )
            }),
            estimatedPreparationBytes: 1_024 * 1_024
        )

        let vodPrepared = try await backend.prepare(request(for: vod, generation: 1))
        let livePrepared = try await backend.prepare(request(for: live, generation: 2))
        let stitchedPrepared = try await backend.prepare(request(for: stitched, generation: 3))

        XCTAssertGreaterThan(vodPrepared.preparedResourceCount, 0)
        XCTAssertEqual(livePrepared.liveWindow?.mediaSequenceRange, 105...107)
        XCTAssertEqual(stitchedPrepared.mediaPlaylistCount, 2)
        XCTAssertGreaterThan(stitchedPrepared.preparedResourceCount, 0)

        let liveRange = try XCTUnwrap(livePrepared.liveWindow?.mediaSequenceRange)
        try QualificationArtifact.write(
            SourceCoverageReport(
                sourceTypes: ["videoOnDemand", "live", "stitched"],
                vodResources: vodPrepared.preparedResourceCount,
                liveResources: livePrepared.preparedResourceCount,
                stitchedResources: stitchedPrepared.preparedResourceCount,
                stitchedPlaylistCount: stitchedPrepared.mediaPlaylistCount,
                liveMediaSequenceLowerBound: liveRange.lowerBound,
                liveMediaSequenceUpperBound: liveRange.upperBound
            ),
            named: "hls-feed-source-coverage.json"
        )
    }

    private func request(
        for item: FeedPlaybackItem,
        generation: UInt64
    ) -> FeedPreparationRequest {
        FeedPreparationRequest(
            item: item,
            generation: .init(rawValue: generation),
            role: .focused,
            maximumLeadingSegments: 2,
            maximumConcurrentFetches: 4
        )
    }

    private func percentile(_ values: [TimeInterval], _ quantile: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(quantile * Double(sorted.count))))
        return sorted[min(sorted.count - 1, rank - 1)]
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
