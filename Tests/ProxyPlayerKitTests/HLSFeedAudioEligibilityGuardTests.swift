import AVFoundation
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedAudioEligibilityGuardTests: XCTestCase {
    func testOffMainNativeChangesAreCoalescedAndCorrectedWithoutPlaying() async throws {
        let player = AVPlayer()
        let guardrail = HLSFeedAudioEligibilityGuard(player: player)
        guardrail.setMuted(true)
        await Task.detached {
            for _ in 0..<100 {
                player.isMuted = false
                player.volume = 1
            }
        }.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while (!player.isMuted || player.volume != 0), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0)
        XCTAssertEqual(player.rate, 0)
        guardrail.stop()
    }

    func testLateNativeChangesCannotUnmuteAnIneligibleFeedPlayer() {
        let player = AVPlayer()
        let guardrail = HLSFeedAudioEligibilityGuard(player: player)
        guardrail.setMuted(true)
        for _ in 0..<100 {
            player.isMuted = false
            player.volume = 1
            XCTAssertTrue(player.isMuted)
            XCTAssertEqual(player.volume, 0)
            XCTAssertEqual(player.rate, 0)
        }
        guardrail.stop()
    }

    func testActivationAndObserverTeardownDoNotFightNormalAudioControls() {
        let player = AVPlayer()
        let guardrail = HLSFeedAudioEligibilityGuard(player: player)
        guardrail.setMuted(true)
        guardrail.setMuted(false)
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(player.volume, 1)
        player.volume = 0.4
        XCTAssertEqual(player.volume, 0.4)
        guardrail.setMuted(true)
        guardrail.stop()
        player.isMuted = false
        player.volume = 0.5
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(player.volume, 0.5)
    }
}
