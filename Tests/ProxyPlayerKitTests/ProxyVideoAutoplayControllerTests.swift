#if canImport(SwiftUI) && canImport(AVKit)
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class ProxyVideoAutoplayControllerTests: XCTestCase {
    func testAutoplayTriggersOncePerLoad() {
        var controller = ProxyVideoAutoplayController()
        let player = AutoplayingStub()

        controller.handleTransition(to: .buffering, autoplay: true, player: player)
        XCTAssertEqual(player.playCallCount, 0)

        controller.handleTransition(to: .ready, autoplay: true, player: player)
        XCTAssertEqual(player.playCallCount, 1)

        controller.handleTransition(to: .ready, autoplay: true, player: player)
        XCTAssertEqual(player.playCallCount, 1)

        controller.handleTransition(to: .ready, autoplay: false, player: player)
        XCTAssertEqual(player.playCallCount, 1)

        controller.reset()
        controller.handleTransition(to: .ready, autoplay: true, player: player)
        XCTAssertEqual(player.playCallCount, 2)
    }
}

private final class AutoplayingStub: ProxyVideoAutoplaying {
    private(set) var playCallCount = 0

    func play() {
        playCallCount += 1
    }
}
#endif
