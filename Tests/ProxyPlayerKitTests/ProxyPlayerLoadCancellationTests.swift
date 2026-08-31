#if canImport(AVFoundation) && canImport(Network)
import Foundation
import HLSCore
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class ProxyPlayerLoadCancellationTests: XCTestCase {
    func testCallerCancellationInterruptsPendingManifestLoad() async throws {
        try await assertCallerCancellation(stitched: false)
    }

    func testCallerCancellationInterruptsPendingStitchedManifestLoad() async throws {
        try await assertCallerCancellation(stitched: true)
    }

    func testAlreadyCancelledCallerDoesNotStartManifestLoad() async throws {
        try await assertCallerCancellation(stitched: false, cancelBeforeLoading: true)
    }

    func testAlreadyCancelledCallerDoesNotStartStitchedManifestLoad() async throws {
        try await assertCallerCancellation(stitched: true, cancelBeforeLoading: true)
    }

    private func assertCallerCancellation(
        stitched: Bool,
        cancelBeforeLoading: Bool = false
    ) async throws {
        // The response cannot arrive inside the cancellation deadline. This
        // checks propagation to owned work, not the speed of normal loading.
        let origin = try FeedFixtureOrigin(profile: .init(responseDelay: .seconds(5)))
        try await origin.start()
        defer { origin.stop() }
        let player = ProxyHLSPlayer(configuration: .init(allowInsecureManifests: true))
        let finished = expectation(description: "Caller acknowledges cancellation")
        let caller = Task { @MainActor in
            if cancelBeforeLoading { withUnsafeCurrentTask { $0?.cancel() } }
            if stitched {
                do {
                    try await player.load(clips: [ProxyPlaybackClip(
                        id: "short-a",
                        playlistURL: origin.fixturePlaylistURL(named: "short-a"),
                        mediaSignature: HLSClipMediaSignature(
                            container: .fragmentedMP4,
                            codecs: ["avc1.640028", "mp4a.40.2"],
                            tracks: [
                                .init(kind: .video, codec: "avc1.640028"),
                                .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
                            ],
                            videoRange: "SDR",
                            segmentsAreIndependent: true
                        )
                    )])
                    XCTFail("Cancelled stitched loading must throw CancellationError")
                } catch is CancellationError {
                    // Expected; cancellation must not become a playback failure.
                } catch {
                    XCTFail("Unexpected cancellation error: \(error)")
                }
            } else {
                await player.load(from: origin.fixturePlaylistURL(named: "short-a"))
            }
            finished.fulfill()
        }
        if !cancelBeforeLoading {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !origin.timelineSnapshot().contains(where: { $0.kind == .requestStarted }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(origin.timelineSnapshot().contains { $0.kind == .requestStarted })
            caller.cancel()
        }
        await fulfillment(of: [finished], timeout: 0.25)
        XCTAssertEqual(player.status, .idle)
        XCTAssertNil(player.player)
        XCTAssertFalse(origin.timelineSnapshot().contains { $0.kind == .responseStarted })
        if cancelBeforeLoading {
            XCTAssertTrue(origin.timelineSnapshot().isEmpty)
        }
        // Also bounds cleanup after a regression: stop explicitly cancels the
        // internal load even if caller cancellation failed to reach it.
        await player.stopAndWait()
        await caller.value
    }
}
#endif
