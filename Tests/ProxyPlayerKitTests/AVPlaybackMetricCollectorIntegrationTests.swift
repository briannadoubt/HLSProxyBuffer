#if canImport(AVFoundation) && canImport(Network)
import AVFoundation
import Foundation
import Network
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class AVPlaybackMetricCollectorIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] != nil, environment["RUN_PROXY_AV_TESTS"] == nil {
            throw XCTSkip("AV metric integration tests require RUN_PROXY_AV_TESTS=1 on CI agents.")
        }
    }

    func testRealProxyPlaybackEmitsNativeAVMetricAndTearsDown() async throws {
        guard #available(
            iOS 18,
            tvOS 18,
            macOS 15,
            macCatalyst 18,
            visionOS 2,
            *
        ) else {
            throw XCTSkip("Native AVMetrics requires the 2024 Apple platform releases.")
        }

        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        let player = ProxyHLSPlayer(configuration: .init(
            bufferPolicy: .init(
                targetBufferSeconds: 1,
                maxPrefetchSegments: 2,
                hideUntilBuffered: false
            ),
            allowInsecureManifests: true
        ))
        await player.load(from: origin.fixturePlaylistURL(named: "short-a"))
        let platformPlayer = try XCTUnwrap(player.player)
        XCTAssertNotNil(platformPlayer.currentItem)

        let correlation = PlaybackAnalytics.Correlation(
            sessionID: .init(),
            playbackID: .init(),
            itemID: .init()
        )
        let collector = AVPlaybackMetricCollector(correlation: correlation)
        let receivedMetric = expectation(description: "native AVMetric event")
        let consumer = Task { @MainActor () -> PlaybackAnalytics.Event? in
            for await event in collector.events {
                if [
                    PlaybackAnalytics.Lifecycle.ready,
                    .rateChanged,
                    .resourceCompleted,
                    .stalled,
                    .recovered,
                    .summaryEmitted,
                ].contains(event.lifecycle) {
                    receivedMetric.fulfill()
                    return event
                }
            }
            return nil
        }

        collector.attach(to: platformPlayer)
        try await waitUntil { collector.snapshot.activeSourceCount == 1 }
        XCTAssertEqual(collector.snapshot.collectionPath, .nativeAVMetrics)
        XCTAssertEqual(collector.snapshot.activeTaskCount, 1)

        player.play()
        await fulfillment(of: [receivedMetric], timeout: 15)
        // Finish the stream even if the expectation timed out. Waiting for the
        // consumer first would leave a failed qualification hanging forever.
        collector.stop()
        let event = await consumer.value
        XCTAssertEqual(event?.source, .avFoundation)
        XCTAssertEqual(event?.correlation, correlation)
        XCTAssertTrue(event?.measurements.allSatisfy { $0.value.isFinite } == true)

        XCTAssertEqual(collector.snapshot.activeSourceCount, 0)
        XCTAssertEqual(collector.snapshot.activeTaskCount, 0)
        XCTAssertEqual(collector.snapshot.activeObserverCount, 0)
        await player.stopAndWait()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for the AV metric source")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
