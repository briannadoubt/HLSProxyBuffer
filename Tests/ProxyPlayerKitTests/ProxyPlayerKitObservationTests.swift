#if canImport(Observation) && canImport(AVFoundation) && canImport(Network)
import XCTest
import Observation
import AVFoundation
import Network
@testable import ProxyPlayerKit
@testable import HLSCore
@testable import LocalProxy

@MainActor
final class ProxyPlayerKitObservationTests: XCTestCase {
    func testTelemetryIsObservableAndAvailableAsBoundedAsyncStream() async {
        let telemetry = HLSStreamingTelemetry(configuration: .init(
            latencyUpperBounds: [0.1, 1]
        ))
        let player = ProxyHLSPlayer(telemetry: telemetry)
        for _ in 0..<10 { await Task.yield() }
        let observed = expectation(description: "Telemetry observation fired")

        withObservationTracking {
            _ = player.telemetrySnapshot.segmentFetchLatency.count
        } onChange: {
            observed.fulfill()
        }

        let stream = await player.telemetryUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await telemetry.recordFetch(.init(
            url: URL(string: "https://cdn.example.com/observed.ts")!,
            duration: 0.2,
            byteCount: 1_024,
            attemptCount: 1,
            retryCount: 0,
            retryOutcome: .successWithoutRetry,
            errorCategory: nil
        ))

        await fulfillment(of: [observed], timeout: 1)
        let streamed = await iterator.next()
        XCTAssertEqual(player.telemetrySnapshot.segmentFetchLatency.count, 1)
        XCTAssertEqual(streamed?.segmentFetchLatency.count, 1)
    }

    func testPlaybackRateIsObservableAndValidated() async {
        let player = ProxyHLSPlayer()
        let expectation = expectation(description: "Playback rate observation fired")

        withObservationTracking {
            _ = player.playbackRate
        } onChange: {
            expectation.fulfill()
        }

        player.setPlaybackRate(1.5)
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(player.playbackRate, 1.5)

        player.setPlaybackRate(10)
        XCTAssertEqual(player.playbackRate, ProxyHLSPlayer.supportedPlaybackRateRange.upperBound)

        player.setPlaybackRate(-1)
        XCTAssertEqual(player.playbackRate, ProxyHLSPlayer.supportedPlaybackRateRange.lowerBound)

        player.setPlaybackRate(.nan)
        XCTAssertEqual(player.playbackRate, 1.0)
    }

    func testStateChangesTriggerObservationCallbacks() async throws {
        let origin = try MockOriginServer()
        try await origin.start()
        defer { origin.stop() }

        let configuration = ProxyPlayerConfiguration(allowInsecureManifests: true)
        let player = ProxyHLSPlayer(configuration: configuration)
        let expectation = expectation(description: "Observation fired")

        withObservationTracking {
            _ = player.state.status
        } onChange: {
            expectation.fulfill()
        }

        await player.load(from: origin.manifestURL, quality: .automatic)
        await fulfillment(of: [expectation], timeout: 5)
        await player.stopAndWait()
    }

    func testAsyncStateStreamDeliversOrderedLifecycleAndStopWaitsForCleanup() async throws {
        let origin = try MockOriginServer(segmentCount: 2)
        try await origin.start()
        defer { origin.stop() }
        let player = ProxyHLSPlayer(configuration: .init(allowInsecureManifests: true))
        let ready = expectation(description: "ready state streamed")
        let streamTask = Task { @MainActor in
            for await state in player.stateUpdates() {
                if state.status == .ready {
                    ready.fulfill()
                    return
                }
            }
        }

        await player.load(from: origin.manifestURL)
        await fulfillment(of: [ready], timeout: 5)
        await player.stopAndWait()
        streamTask.cancel()

        XCTAssertEqual(player.status, .idle)
        XCTAssertNil(player.player)
    }
}
#endif
