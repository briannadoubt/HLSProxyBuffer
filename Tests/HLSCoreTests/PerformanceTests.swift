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
            let expectation = expectation(description: "prefetch")
            let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 8, maxSegments: 8))
            let cache = HLSSegmentCache(capacity: 8)
            let fetcher = MockSegmentSource()

            Task {
                await scheduler.start(playlist: playlist, fetcher: fetcher, cache: cache)
                expectation.fulfill()
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
