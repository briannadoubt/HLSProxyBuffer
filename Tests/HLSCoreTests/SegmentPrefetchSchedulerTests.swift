import XCTest
@testable import HLSCore

final class SegmentPrefetchSchedulerTests: XCTestCase {
    func testPolicyRefreshDoesNotPrefetchConsumedSegmentsAgain() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 4, maxSegments: 1))
        let cache = HLSSegmentCache(capacityBytes: 1024)
        let segments = try (1...3).map { sequence in
            HLSSegment(url: try XCTUnwrap(URL(string: "https://cdn.test/\(sequence).ts")), duration: 4, sequence: sequence)
        }
        await scheduler.start(playlist: MediaPlaylist(targetDuration: 4, segments: segments),
                              fetcher: MockSegmentSource(), cache: cache)
        try await waitForReady(1, scheduler: scheduler)
        await scheduler.consume(sequence: 1)
        try await waitForReady(2, scheduler: scheduler)
        await scheduler.enqueueUpcomingPlaylists([])
        await scheduler.consume(sequence: 2)
        try await waitForReady(3, scheduler: scheduler)
        let state = await scheduler.bufferState()
        XCTAssertEqual(state.readySequences, [3])
        await scheduler.stop()
    }

    func testRewindRefetchesEvictedMediaAndContinuesForward() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 4, maxSegments: 1))
        let cache = HLSSegmentCache(capacityBytes: 1024)
        let fetcher = MockSegmentSource()
        let segments = try (1...3).map { sequence in
            HLSSegment(url: try XCTUnwrap(URL(string: "https://cdn.test/\(sequence).ts")), duration: 4, sequence: sequence)
        }
        await scheduler.start(playlist: MediaPlaylist(targetDuration: 4, segments: segments), fetcher: fetcher, cache: cache)
        try await waitForReady(1, scheduler: scheduler)
        await scheduler.consume(sequence: 1)
        try await waitForReady(2, scheduler: scheduler)
        await scheduler.consume(sequence: 2)
        try await waitForReady(3, scheduler: scheduler)
        await cache.clear()
        let repositioned = await scheduler.reposition(to: 1)
        XCTAssertTrue(repositioned)
        try await waitForReady(1, scheduler: scheduler)
        let state = await scheduler.bufferState()
        XCTAssertNil(state.playedThroughSequence)
        XCTAssertEqual(state.readySequences, [1])
        let firstFetches = await fetcher.count(for: 1)
        XCTAssertEqual(firstFetches, 2, "Rewind must refetch bytes removed by cache pressure")
        await scheduler.consume(sequence: 1)
        try await waitForReady(2, scheduler: scheduler)
        let secondFetches = await fetcher.count(for: 2)
        XCTAssertEqual(secondFetches, 2)
        let rejected = await scheduler.reposition(to: 999)
        XCTAssertFalse(rejected)
        let unchanged = await scheduler.bufferState()
        XCTAssertEqual(unchanged.playedThroughSequence, 1)
        await scheduler.stop()
    }

    func testConsumedPrimarySequenceDoesNotSuppressUpcomingPlaylist() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 4, maxSegments: 1))
        let cache = HLSSegmentCache(capacityBytes: 1024)
        let primary = HLSSegment(url: try XCTUnwrap(URL(string: "https://cdn.test/current.ts")), duration: 4, sequence: 10)
        let next = HLSSegment(url: try XCTUnwrap(URL(string: "https://cdn.test/next.ts")), duration: 4, sequence: 1)
        await scheduler.enqueueUpcomingPlaylists([MediaPlaylist(targetDuration: 4, segments: [next])])
        await scheduler.start(playlist: MediaPlaylist(targetDuration: 4, segments: [primary]), fetcher: MockSegmentSource(), cache: cache)
        try await waitForReady(10, scheduler: scheduler)
        await scheduler.consume(sequence: 10)
        try await waitForReady(1, scheduler: scheduler)
        let bytes = await cache.get(SegmentIdentity.key(for: next))
        XCTAssertNotNil(bytes)
        await scheduler.stop()
    }

    private func waitForReady(_ sequence: Int, scheduler: SegmentPrefetchScheduler) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if await scheduler.bufferState().readySequences.contains(sequence) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected sequence \(sequence) in forward buffer")
    }

    func testUpcomingPlaylistsArePrefetched() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 12, maxSegments: 4))
        let cache = HLSSegmentCache(capacityBytes: 1_024)
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

        let upcomingData = await cache.get(SegmentIdentity.key(for: upcoming.segments[0]))
        XCTAssertNotNil(upcomingData, "Upcoming playlist segment should be prefetched.")
    }

    func testTelemetryReportsFailures() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(
            targetBufferSeconds: 4,
            maxSegments: 1,
            maximumRetryCount: 0
        ))
        let cache = HLSSegmentCache(capacityBytes: 1_024)
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
        await scheduler.stop()
    }

    func testFailedPrefetchRetriesTheHoleAndRecovers() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(
            targetBufferSeconds: 4,
            maxSegments: 1,
            maximumRetryCount: 0,
            retryBaseDelay: 0.01
        ))
        let cache = HLSSegmentCache(capacityBytes: 1_024)
        let fetcher = RecoveringSegmentSource(failuresBeforeSuccess: 1)
        let segment = HLSSegment(
            url: URL(string: "https://cdn.test/recover.ts")!,
            duration: 4,
            sequence: 1
        )
        await scheduler.start(
            playlist: MediaPlaylist(targetDuration: 4, segments: [segment]),
            fetcher: fetcher,
            cache: cache
        )

        let key = SegmentIdentity.key(for: segment)
        for _ in 0..<100 {
            if await cache.get(key) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let cached = await cache.get(key)
        let count = await fetcher.fetchCount()
        XCTAssertNotNil(cached)
        XCTAssertEqual(count, 2)
        await scheduler.stop()
    }

    func testConsumeReducesBufferDepth() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 8, maxSegments: 2))
        let cache = HLSSegmentCache(capacityBytes: 1_024)
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
        let cache = HLSSegmentCache(capacityBytes: 1_024)
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

    func testConsumeJumpClearsAllEarlierBufferedSequences() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 12, maxSegments: 3))
        let cache = HLSSegmentCache(capacityBytes: 1_024)
        let segments = (1...3).map {
            HLSSegment(url: URL(string: "https://cdn.test/\($0).ts")!, duration: 4, sequence: $0)
        }
        await scheduler.start(
            playlist: MediaPlaylist(targetDuration: 4, segments: segments),
            fetcher: MockSegmentSource(),
            cache: cache
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        await scheduler.consume(sequence: 3)
        let state = await scheduler.bufferState()

        XCTAssertTrue(state.readySequences.isEmpty)
        XCTAssertEqual(state.prefetchDepthSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(state.playedThroughSequence, 3)
        await scheduler.stop()
    }

    func testPrefetchesPartsAndTracksReadyCount() async throws {
        let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 2, maxSegments: 1, targetPartCount: 2))
        let cache = HLSSegmentCache(capacityBytes: 1_024)
        let fetcher = MockSegmentSource()

        let part0 = HLSPartialSegment(
            parentSequence: 1,
            partIndex: 0,
            duration: 0.5,
            url: URL(string: "https://cdn.test/1-part0.ts")!
        )
        let part1 = HLSPartialSegment(
            parentSequence: 1,
            partIndex: 1,
            duration: 0.5,
            url: URL(string: "https://cdn.test/1-part1.ts")!
        )

        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(
                    url: URL(string: "https://cdn.test/1.ts")!,
                    duration: 4,
                    sequence: 1,
                    parts: [part0, part1]
                )
            ]
        )

        await scheduler.start(playlist: playlist, fetcher: fetcher, cache: cache)
        try await Task.sleep(nanoseconds: 200_000_000)

        var state = await scheduler.bufferState()
        XCTAssertEqual(state.readyPartCounts[1], 2)
        XCTAssertGreaterThanOrEqual(state.partPrefetchDepthSeconds, 1.0)

        await scheduler.consumePart(sequence: 1, partIndex: 0)
        state = await scheduler.bufferState()
        XCTAssertEqual(state.readyPartCounts[1], 1)
    }

    func testRemovingBufferCallbackWaitsForInFlightDelivery() async throws {
        let scheduler = SegmentPrefetchScheduler()
        let gate = SchedulerCallbackGate()

        await scheduler.onBufferStateChange { _ in
            await gate.wait()
        }

        for _ in 0..<100 {
            if await gate.isWaiting { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let callbackIsWaiting = await gate.isWaiting
        XCTAssertTrue(callbackIsWaiting)

        let removal = Task {
            await scheduler.onBufferStateChange(nil)
            await gate.markRemovalCompleted()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let completedBeforeRelease = await gate.removalCompleted
        XCTAssertFalse(completedBeforeRelease)

        await gate.release()
        await removal.value
        let completedAfterRelease = await gate.removalCompleted
        XCTAssertTrue(completedAfterRelease)
    }
}

private actor SchedulerCallbackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private(set) var removalCompleted = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }

    func markRemovalCompleted() {
        removalCompleted = true
    }
}

private actor MockSegmentSource: SegmentSource {
    private var counts: [Int: Int] = [:]
    func count(for sequence: Int) -> Int { counts[sequence, default: 0] }
    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        counts[segment.sequence, default: 0] += 1
        return Data("\(segment.sequence)".utf8)
    }
}

private actor FailingSegmentSource: SegmentSource {
    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        throw URLError(.badServerResponse)
    }
}

private actor RecoveringSegmentSource: SegmentSource {
    private var failuresRemaining: Int
    private var count = 0

    init(failuresBeforeSuccess: Int) {
        failuresRemaining = failuresBeforeSuccess
    }

    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        count += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.timedOut)
        }
        return Data("recovered".utf8)
    }

    func fetchCount() -> Int { count }
}
