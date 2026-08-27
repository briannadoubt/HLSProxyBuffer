import XCTest
@testable import HLSCore

final class PerformanceTests: XCTestCase {
    func testSegmentSchedulerPerformance() {
        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: (1...8).map {
                HLSSegment(url: URL(string: "https://cdn.example.com/\($0).ts")!, duration: 1, sequence: $0)
            }
        )

        measure(metrics: [XCTClockMetric()]) {
            let expectation = expectation(description: "prefetch completed")
            let scheduler = SegmentPrefetchScheduler(configuration: .init(
                targetBufferSeconds: 8,
                maxSegments: 8,
                maxConcurrentFetches: 4
            ))
            let cache = HLSSegmentCache(capacityBytes: 1_024)
            let fetcher = MockSegmentSource()

            Task {
                let states = await scheduler.states()
                await scheduler.start(playlist: playlist, fetcher: fetcher, cache: cache)
                for await state in states where state.readySequences.count == 8 {
                    expectation.fulfill()
                    break
                }
            }

            wait(for: [expectation], timeout: 2.0)
        }
    }
}

private actor MockSegmentSource: SegmentSource {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        try await Task.sleep(nanoseconds: 1_000_000)
        return Data("\(segment.sequence)".utf8)
    }
}
