import XCTest
@testable import LocalProxy

final class PlaylistStoreTests: XCTestCase {
    func testBlockingSnapshotWakesWhenRequestedSequenceArrives() async throws {
        let store = PlaylistStore()
        await store.update(playlist(sequence: 10))

        let waiter = Task {
            await store.snapshot(waitingForMediaSequence: 11, part: nil, timeout: 1)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.update(playlist(sequence: 11))

        let result = await waiter.value
        XCTAssertTrue(result.contains("#EXT-X-MEDIA-SEQUENCE:11"))
    }

    func testDeltaSkipCountsTowardAvailableMediaSequence() async {
        let store = PlaylistStore()
        let delta = [
            "#EXTM3U",
            "#EXT-X-MEDIA-SEQUENCE:10",
            "#EXT-X-SKIP:SKIPPED-SEGMENTS=5",
            "#EXTINF:2.0,",
            "segment-15.m4s"
        ].joined(separator: "\n")
        await store.update(delta)

        let clock = ContinuousClock()
        let start = clock.now
        let result = await store.snapshot(waitingForMediaSequence: 15, part: nil, timeout: 0.5)

        XCTAssertEqual(result, delta)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(100))
    }

    func testBlockingTimeoutReturnsLatestSnapshot() async throws {
        let store = PlaylistStore()
        await store.update(playlist(sequence: 10))
        let waiter = Task {
            await store.snapshot(waitingForMediaSequence: 20, part: nil, timeout: 0.08)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await store.update(playlist(sequence: 11))

        let result = await waiter.value
        XCTAssertTrue(result.contains("#EXT-X-MEDIA-SEQUENCE:11"))
    }

    private func playlist(sequence: Int) -> String {
        [
            "#EXTM3U",
            "#EXT-X-MEDIA-SEQUENCE:\(sequence)",
            "#EXTINF:2.0,",
            "segment-\(sequence).m4s"
        ].joined(separator: "\n")
    }
}
