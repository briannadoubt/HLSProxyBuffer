import XCTest
@testable import ProxyPlayerKit

final class HLSFeedPlaybackStartTimingTests: XCTestCase {
    func testStagesPartitionTheOriginalFocusToConfirmationInterval() {
        var timing = HLSFeedPlaybackStartTiming(requestedAt: .seconds(1))
        timing.activationBeganAt = .milliseconds(1_100)
        timing.playInvokedAt = .milliseconds(1_120)
        XCTAssertEqual(
            timing.sample(nativePlayingAt: .milliseconds(1_400), confirmedAt: .milliseconds(1_430)),
            .playbackStartStages(beforeActivation: 0.1, activationWork: 0.02,
                                 nativeStart: 0.28, callbackDelivery: 0.03)
        )
    }

    func testIncompleteOrNonMonotonicObservationsDoNotInventStageEvidence() {
        var timing = HLSFeedPlaybackStartTiming(requestedAt: .seconds(1))
        XCTAssertNil(timing.sample(nativePlayingAt: .seconds(2), confirmedAt: .seconds(3)))
        timing.activationBeganAt = .milliseconds(900)
        timing.playInvokedAt = .milliseconds(1_200)
        XCTAssertNil(timing.sample(nativePlayingAt: .seconds(2), confirmedAt: .seconds(3)))
        timing.activationBeganAt = .milliseconds(1_100)
        timing.playInvokedAt = .milliseconds(1_050)
        XCTAssertNil(timing.sample(nativePlayingAt: .seconds(2), confirmedAt: .seconds(3)))
        timing.playInvokedAt = .milliseconds(1_200)
        XCTAssertNil(timing.sample(nativePlayingAt: .milliseconds(1_100), confirmedAt: .seconds(3)))
        XCTAssertNil(timing.sample(nativePlayingAt: .seconds(2), confirmedAt: .milliseconds(1_900)))
    }

    @MainActor
    func testStageAggregationIsBoundedAndDoesNotChangeEndToEndSamples() throws {
        let telemetry = HLSFeedTelemetry()
        let path = HLSFeedTelemetry.Path(reuse: .warm, intent: .focused, mediaKind: .videoOnDemand)
        telemetry.record(.init(path: path, payload: .firstFrame(latency: 0.75)))
        for _ in 0..<1_000 {
            telemetry.record(.init(path: path, payload: .playbackStartStages(
                beforeActivation: 0.1, activationWork: 0.02, nativeStart: 0.6, callbackDelivery: 0.03
            )))
        }
        let metrics = try XCTUnwrap(telemetry.snapshot.metrics(for: path))
        let stages = try XCTUnwrap(metrics.playbackStartStages)
        XCTAssertEqual(metrics.firstFrameLatency.count, 1)
        XCTAssertEqual(metrics.firstFrameLatency.maximum, 0.75)
        XCTAssertEqual(metrics.firstFrameLatency.approximateQuantile(0.95), 1)
        XCTAssertEqual(stages.beforeActivation.count, 1_000)
        XCTAssertEqual(stages.activationWork.maximum, 0.02)
        XCTAssertEqual(stages.nativeStart.maximum, 0.6)
        XCTAssertEqual(stages.callbackDelivery.maximum, 0.03)
        XCTAssertEqual(telemetry.snapshot.storageBound.histogramCount, 96)
        XCTAssertEqual(stages.nativeStart.bucketCounts.count, 12)
        let decoded = try JSONDecoder().decode(HLSFeedTelemetry.Snapshot.self, from: telemetry.machineReadableSummary())
        XCTAssertEqual(decoded.metrics(for: path)?.playbackStartStages, stages)
    }
}
