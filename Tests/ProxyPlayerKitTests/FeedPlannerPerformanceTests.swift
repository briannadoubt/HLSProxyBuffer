import XCTest
@testable import ProxyPlayerKit

final class FeedPlannerPerformanceTests: XCTestCase {
    func testTenThousandSignalUpdatesStayBelowOneMillisecondP95() throws {
        let itemCount = 64
        let iterations = 10_000
        let items = (0..<itemCount).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "item-\(index)"),
                source: .stream(
                    url: URL(fileURLWithPath: "/fixtures/item-\(index).m3u8"),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 512 * 1_024
            )
        }
        let planner = FeedPlanner(limits: .init(
            maximumResidentItems: 5,
            maximumPrefetchItems: 4,
            maximumConcurrentPreparations: 4,
            maximumEstimatedPreparationBytes: 8 * 1_024 * 1_024,
            neighborPredictionHorizon: 4
        ))
        let clock = ContinuousClock()
        var samples: [Duration] = []
        samples.reserveCapacity(iterations)
        var previousPlan: FeedPlan?

        for iteration in 0..<iterations {
            let focusedIndex = iteration % itemCount
            let signal = FeedViewportSignal(
                generation: .init(rawValue: UInt64(iteration)),
                focusedItemID: items[focusedIndex].id,
                visibleItems: [
                    .init(itemID: items[focusedIndex].id, fraction: 1, distanceInViewports: 0)
                ],
                velocityInViewportsPerSecond: iteration.isMultiple(of: 2) ? 3 : -3,
                predictedDestinations: [
                    .init(itemID: items[(focusedIndex + 1) % itemCount].id, confidence: 0.9)
                ],
                observedAt: .milliseconds(iteration)
            )
            let start = clock.now
            previousPlan = try planner.makePlan(
                items: items,
                signal: signal,
                previousPlan: previousPlan
            )
            samples.append(start.duration(to: clock.now))
        }

        samples.sort()
        let p95 = samples[(samples.count * 95) / 100]
        XCTAssertLessThanOrEqual(
            p95,
            .milliseconds(1),
            "10,000-update feed-planning p95 exceeded the 1 ms contract: \(p95)"
        )
    }
}
