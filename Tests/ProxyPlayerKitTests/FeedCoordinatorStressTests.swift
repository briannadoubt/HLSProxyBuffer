import Foundation
import XCTest
@testable import ProxyPlayerKit

final class FeedCoordinatorStressTests: XCTestCase {
    private struct StressReport: Codable {
        let transitionCount: Int
        let maximumObservedActivePreparations: Int
        let maximumConcurrentPreparationLimit: Int
        let maximumResidentItemCount: Int
        let maximumResidentItemLimit: Int
        let maximumResidentEstimatedBytes: Int
        let maximumResidentEstimatedByteLimit: Int
        let cancellationRequestCount: Int
        let cancellationAcknowledgementCount: Int
        let cancellationMaximumMilliseconds: Double
        let cancellationDeadlineMilliseconds: Double
        let lateCancellationCount: Int
        let discardedStaleResultCount: Int
    }

    func testAllStandardTracesKeepCoordinatorWorkWithinHardBounds() async throws {
        let items = makeItems(count: 11)
        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.concurrency.maximumConcurrentPreparations = 2
        policy.budget.maximumResidentItems = 4
        policy.budget.maximumEstimatedPreparationBytes = 4 * 512 * 1_024
        let backend = StressFeedPreparationBackend(delay: .milliseconds(2))
        let coordinator = try FeedCoordinator(items: items, policy: policy, backend: backend)
        var generation: UInt64 = 0
        var observationCount = 0
        var maximumResidentItemCount = 0
        var maximumResidentEstimatedBytes = 0

        for trace in FeedNavigationTrace.standardCatalog(itemCount: items.count) {
            for source in try trace.signals(for: items) {
                generation += 1
                observationCount += 1
                let signal = FeedViewportSignal(
                    generation: .init(rawValue: generation),
                    focusedItemID: source.focusedItemID,
                    visibleItems: source.visibleItems,
                    velocityInViewportsPerSecond: source.velocityInViewportsPerSecond,
                    predictedDestinations: source.predictedDestinations,
                    observedAt: source.observedAt
                )
                let snapshot = try await coordinator.submit(signal)
                maximumResidentItemCount = max(maximumResidentItemCount, snapshot.entries.count)
                maximumResidentEstimatedBytes = max(
                    maximumResidentEstimatedBytes,
                    snapshot.residentEstimatedPreparationBytes
                )
                XCTAssertLessThanOrEqual(snapshot.activePreparationCount, 2)
                XCTAssertLessThanOrEqual(snapshot.entries.count, 4)
                XCTAssertLessThanOrEqual(
                    snapshot.entries.reduce(0) { $0 + $1.estimatedPreparationBytes },
                    policy.budget.maximumEstimatedPreparationBytes
                )
                if generation.isMultiple(of: 12) {
                    await Task.yield()
                }
            }
        }

        let settled = await coordinator.waitUntilIdle()
        maximumResidentItemCount = max(maximumResidentItemCount, settled.entries.count)
        maximumResidentEstimatedBytes = max(
            maximumResidentEstimatedBytes,
            settled.residentEstimatedPreparationBytes
        )
        let backendMaximum = await backend.maximumObservedActiveCount()
        XCTAssertEqual(observationCount, 532)
        XCTAssertLessThanOrEqual(settled.maximumObservedActivePreparations, 2)
        XCTAssertLessThanOrEqual(backendMaximum, 2)
        XCTAssertGreaterThan(settled.cancellationRequestCount, 100)
        XCTAssertEqual(
            settled.cancellationAcknowledgementCount,
            settled.cancellationRequestCount
        )
        XCTAssertEqual(settled.lateCancellationCount, 0)
        let cancellationMaximum = settled.maximumCancellationLatency?.seconds ?? 0
        XCTAssertLessThanOrEqual(cancellationMaximum, 0.250)
        XCTAssertEqual(settled.generation, .init(rawValue: generation))
        XCTAssertTrue(settled.readyItemIDs.contains(try XCTUnwrap(settled.entries.first?.itemID)))
        try QualificationArtifact.write(
            StressReport(
                transitionCount: observationCount,
                maximumObservedActivePreparations: settled.maximumObservedActivePreparations,
                maximumConcurrentPreparationLimit: policy.concurrency.maximumConcurrentPreparations,
                maximumResidentItemCount: maximumResidentItemCount,
                maximumResidentItemLimit: policy.budget.maximumResidentItems,
                maximumResidentEstimatedBytes: maximumResidentEstimatedBytes,
                maximumResidentEstimatedByteLimit: policy.budget.maximumEstimatedPreparationBytes,
                cancellationRequestCount: settled.cancellationRequestCount,
                cancellationAcknowledgementCount: settled.cancellationAcknowledgementCount,
                cancellationMaximumMilliseconds: cancellationMaximum * 1_000,
                cancellationDeadlineMilliseconds: 250,
                lateCancellationCount: settled.lateCancellationCount,
                discardedStaleResultCount: settled.discardedStaleResultCount
            ),
            named: "hls-feed-coordinator-stress.json"
        )
    }
}

private extension FeedCoordinatorStressTests {
    func makeItems(count: Int) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "stress-item-\(index)"),
                source: .stream(
                    url: URL(string: "https://fixture.invalid/stress-\(index).m3u8")!,
                    kind: index.isMultiple(of: 3) ? .live : .videoOnDemand
                ),
                estimatedPreparationBytes: 512 * 1_024
            )
        }
    }
}

private actor StressFeedPreparationBackend: FeedPreparing {
    private let delay: Duration
    private var activeCount = 0
    private var maximumActiveCount = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func prepare(_ request: FeedPreparationRequest) async throws -> FeedPreparedItem {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        defer { activeCount -= 1 }
        try await Task.sleep(for: delay)
        return FeedPreparedItem(
            itemID: request.item.id,
            generation: request.generation,
            manifestURLs: [],
            mediaPlaylistCount: 1,
            leadingSegmentCount: request.maximumLeadingSegments,
            preparedResourceCount: request.maximumLeadingSegments,
            preparedByteCount: request.maximumLeadingSegments * 512,
            cacheHitCount: 0,
            originFetchCount: request.maximumLeadingSegments
        )
    }

    func maximumObservedActiveCount() -> Int {
        maximumActiveCount
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
