import XCTest
@testable import HLSCore

final class SegmentPrefetchSchedulerTests: XCTestCase {
    func testUpcomingPlaylistsArePrefetched() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 12, maxSegments: 4))
        let cache = HLSSegmentCache(capacity: 4)
        let fetcher = MockSegmentSource()

        let primary = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.test/1.ts")!, duration: 4, sequence: 1),
                HLSSegment(url: URL(string: "https://cdn.test/2.ts")!, duration: 4, sequence: 2),
            ]
        )

        let upcoming = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 10,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.test/10.ts")!, duration: 4, sequence: 10),
            ]
        )

        await scheduler.enqueueUpcomingPlaylists([upcoming])
        await scheduler.start(playlist: primary, fetcher: fetcher, cache: cache)
        try await Task.sleep(nanoseconds: 200_000_000)

        let upcomingData = await cache.get(SegmentIdentity.key(forSequence: 10))
        XCTAssertNotNil(upcomingData, "Upcoming playlist segment should be prefetched.")
    }

    func testTelemetryReportsFailures() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 4, maxSegments: 1))
        let cache = HLSSegmentCache(capacity: 2)
        let fetcher = FailingSegmentSource()
        let expectation = expectation(description: "telemetry")

        await scheduler.onTelemetry { telemetry in
            if telemetry.failureCount > 0 {
                expectation.fulfill()
            }
        }

        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.test/fail.ts")!, duration: 4, sequence: 1),
            ]
        )

        await scheduler.start(playlist: playlist, fetcher: fetcher, cache: cache)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    func testConsumeReducesBufferDepth() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 8, maxSegments: 2))
        let cache = HLSSegmentCache(capacity: 2)
        let fetcher = MockSegmentSource()

        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.test/1.ts")!, duration: 4, sequence: 1),
                HLSSegment(url: URL(string: "https://cdn.test/2.ts")!, duration: 4, sequence: 2),
            ]
        )

        await scheduler.start(playlist: playlist, fetcher: fetcher, cache: cache)
        try await Task.sleep(nanoseconds: 200_000_000)

        var state = await scheduler.bufferState()
        XCTAssertEqual(state.prefetchDepthSeconds, 8, accuracy: 0.001)

        await scheduler.consume(sequence: 1)
        state = await scheduler.bufferState()
        XCTAssertEqual(state.prefetchDepthSeconds, 4, accuracy: 0.001)

        await scheduler.consume(sequence: 2)
        state = await scheduler.bufferState()
        XCTAssertEqual(state.prefetchDepthSeconds, 0, accuracy: 0.001)
    }

    func testPrefetchesNextSegmentAfterConsumption() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 4, maxSegments: 1))
        let cache = HLSSegmentCache(capacity: 2)
        let fetcher = MockSegmentSource()

        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.test/1.ts")!, duration: 4, sequence: 1),
                HLSSegment(url: URL(string: "https://cdn.test/2.ts")!, duration: 4, sequence: 2),
                HLSSegment(url: URL(string: "https://cdn.test/3.ts")!, duration: 4, sequence: 3),
            ]
        )

        await scheduler.start(playlist: playlist, fetcher: fetcher, cache: cache)
        try await Task.sleep(nanoseconds: 200_000_000)

        var state = await scheduler.bufferState()
        XCTAssertTrue(state.readySequences.contains(1))

        await scheduler.consume(sequence: 1)
        try await Task.sleep(nanoseconds: 200_000_000)

        state = await scheduler.bufferState()
        XCTAssertTrue(state.readySequences.contains(2))

        await scheduler.consume(sequence: 2)
        try await Task.sleep(nanoseconds: 200_000_000)

        state = await scheduler.bufferState()
        XCTAssertTrue(state.readySequences.contains(3))
    }

    func testConsumeAdvancesPlayheadEvenWhenNotBuffered() async throws {
        let scheduler = SegmentPrefetchScheduler()
        await scheduler.consume(sequence: 10)
        let state = await scheduler.bufferState()
        XCTAssertEqual(state.playedThroughSequence, 10)
    }
}

private actor MockSegmentSource: SegmentSource {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        Data("\(segment.sequence)".utf8)
    }
}

private actor FailingSegmentSource: SegmentSource {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        throw URLError(.badServerResponse)
    }
}
