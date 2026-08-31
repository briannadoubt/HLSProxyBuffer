import AVFoundation
import XCTest
import os
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedVideoOutputObserverTests: XCTestCase {
    func testOffMainLastReleaseDetachesOutputAndReleasesSampler() async throws {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let ownership = OSAllocatedUnfairLock(initialState: Optional(HLSFeedVideoOutputObserver(item: item)))
        ownership.withLock { $0 }?.start(requestedAt: .zero, clock: .continuous, record: { _ in })
        weak var released = ownership.withLock { $0 }
        XCTAssertEqual(item.outputs.count, 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                ownership.withLock { $0 = nil }
                continuation.resume()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !item.outputs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(released)
        XCTAssertTrue(item.outputs.isEmpty)
    }

    func testPreparationAndPauseRetainOutputWithoutSampling() throws {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let observer = HLSFeedVideoOutputObserver(item: item)
        XCTAssertTrue(observer.isAttached(to: item))
        XCTAssertFalse(observer.isSampling)
        let output = try XCTUnwrap(item.outputs.first)
        XCTAssertFalse(output.suppressesPlayerRendering)

        observer.start(requestedAt: .zero, clock: .continuous, record: { _ in })
        XCTAssertTrue(observer.isSampling)
        observer.pause()
        XCTAssertFalse(observer.isSampling)
        XCTAssertEqual(item.outputs.count, 1)
        XCTAssertTrue(item.outputs.first === output)
        observer.start(requestedAt: nil, clock: .continuous, record: { _ in })
        XCTAssertTrue(observer.isSampling)
        XCTAssertTrue(item.outputs.first === output)
        observer.stop()
        XCTAssertFalse(observer.isSampling)
        XCTAssertTrue(item.outputs.isEmpty)
        observer.start(requestedAt: nil, clock: .continuous, record: { _ in })
        XCTAssertFalse(observer.isSampling, "A retired output cannot restart")
    }

    func testDeinitDetachesPreparedOutputAndReleasesSampler() {
        let item = AVPlayerItem(asset: AVMutableComposition())
        var observer: HLSFeedVideoOutputObserver? = HLSFeedVideoOutputObserver(item: item)
        weak var released = observer
        observer?.start(requestedAt: .zero, clock: .continuous, record: { _ in })
        XCTAssertEqual(item.outputs.count, 1)
        observer = nil
        XCTAssertNil(released)
        XCTAssertTrue(item.outputs.isEmpty)
    }
}
