import AVFoundation
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedVideoOutputObserverTests: XCTestCase {
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
