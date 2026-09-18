import XCTest
@testable import HLSCore

final class AdaptiveVariantControllerTests: XCTestCase {
    private func makeVariant(name: String, bandwidth: Int) -> VariantPlaylist {
        VariantPlaylist(
            url: URL(string: "https://example.com/\(name).m3u8")!,
            attributes: .init(bandwidth: bandwidth, averageBandwidth: bandwidth)
        )
    }

    private func makeSample(_ value: Double) -> ThroughputEstimator.Sample {
        ThroughputEstimator.Sample(bitsPerSecond: value, lastSampleDate: Date())
    }

    private func makeBufferState(seconds: Double = 4, playedSequence: Int? = 0) -> BufferState {
        BufferState(readySequences: [], prefetchDepthSeconds: seconds, playedThroughSequence: playedSequence)
    }

    func testRecommendsUpgradeWhenThroughputIsHigh() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController()
        await controller.updateVariants([low, high])

        let decision = await controller.evaluate(
            currentVariant: low,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: makeBufferState()
        )

        XCTAssertEqual(decision.action, .switchVariant)
        XCTAssertEqual(decision.targetVariant, high)
        XCTAssertEqual(decision.reason, .throughputIncreased)
    }

    func testRecommendsDowngradeWhenThroughputFalls() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController()
        await controller.updateVariants([low, high])

        let decision = await controller.evaluate(
            currentVariant: high,
            qualityPolicy: .automatic,
            throughputSample: makeSample(200_000),
            bufferState: makeBufferState()
        )

        XCTAssertEqual(decision.action, .switchVariant)
        XCTAssertEqual(decision.targetVariant, low)
        XCTAssertEqual(decision.reason, .throughputDecreased)
    }

    func testDowngradesAfterFailures() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController(policy: .init(failureDowngradeThreshold: 2))
        await controller.updateVariants([low, high])

        await controller.registerFailure()
        await controller.registerFailure()

        let decision = await controller.evaluate(
            currentVariant: high,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: makeBufferState()
        )

        XCTAssertEqual(decision.action, .switchVariant)
        XCTAssertEqual(decision.targetVariant, low)
        XCTAssertEqual(decision.reason, .consecutiveFailures)
    }

    func testHysteresisPreventsChatter() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController()
        await controller.updateVariants([low, high])

        // Throughput clears base threshold but not the hysteresis guard.
        let throughput = Double(high.attributes.bandwidth ?? 0) * 1.2 * 1.02
        let decision = await controller.evaluate(
            currentVariant: low,
            qualityPolicy: .automatic,
            throughputSample: makeSample(throughput),
            bufferState: makeBufferState()
        )

        XCTAssertEqual(decision.action, .hold)
        XCTAssertEqual(decision.reason, .hysteresis)
    }

    func testMinimumIntervalBlocksRapidSwitches() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController(policy: .init(minimumSwitchInterval: 30))
        await controller.updateVariants([low, high])

        let upgradeDecision = await controller.evaluate(
            currentVariant: low,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: makeBufferState()
        )
        XCTAssertEqual(upgradeDecision.action, .switchVariant)
        XCTAssertEqual(upgradeDecision.targetVariant, high)

        let downgradeDecision = await controller.evaluate(
            currentVariant: high,
            qualityPolicy: .automatic,
            throughputSample: makeSample(100_000),
            bufferState: makeBufferState()
        )
        XCTAssertEqual(downgradeDecision.action, .hold)
        XCTAssertEqual(downgradeDecision.reason, .minimumInterval)
    }

    func testIgnoresBufferDepletionBeforeInitialFill() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController()
        await controller.updateVariants([low, high])

        let emptyState = BufferState(readySequences: [], prefetchDepthSeconds: 0, playedThroughSequence: nil)
        let initialDecision = await controller.evaluate(
            currentVariant: high,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: emptyState
        )
        XCTAssertEqual(initialDecision.action, .hold)

        let startedState = BufferState(readySequences: [1], prefetchDepthSeconds: 2, playedThroughSequence: 0)
        _ = await controller.evaluate(
            currentVariant: high,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: startedState
        )

        let depletedDecision = await controller.evaluate(
            currentVariant: high,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: BufferState(readySequences: [], prefetchDepthSeconds: 0, playedThroughSequence: 0)
        )
        XCTAssertEqual(depletedDecision.action, .switchVariant)
        XCTAssertEqual(depletedDecision.targetVariant, low)
        XCTAssertEqual(depletedDecision.reason, .bufferDepleted)
    }

    func testSkipsABRDecisionsBeforePlaybackStarts() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 1_500_000)
        let controller = AdaptiveVariantController()
        await controller.updateVariants([low, high])

        let prefetchedState = BufferState(readySequences: [0, 1], prefetchDepthSeconds: 4, playedThroughSequence: nil)
        let decision = await controller.evaluate(
            currentVariant: low,
            qualityPolicy: .automatic,
            throughputSample: makeSample(3_000_000),
            bufferState: prefetchedState
        )

        XCTAssertEqual(decision.action, .hold)
        XCTAssertEqual(decision.reason, .boundaryReached)
    }
    func testNativeVariantsChooseAffordableCeilingBeforeFirstCompletedSegment() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let medium = makeVariant(name: "medium", bandwidth: 1_000_000)
        let high = makeVariant(name: "high", bandwidth: 2_000_000)
        for (throughput, expected) in [(4_000_000.0, high), (1_500_000.0, medium)] {
            let controller = AdaptiveVariantController()
            await controller.updateVariants([low, medium, high])
            let decision = await controller.evaluate(
                currentVariant: low, qualityPolicy: .automatic,
                throughputSample: makeSample(throughput),
                bufferState: makeBufferState(playedSequence: nil),
                adaptationMode: .nativeVariants
            )
            XCTAssertEqual(decision.action, .switchVariant)
            XCTAssertEqual(decision.targetVariant, expected)
        }
    }

    func testNativeVariantsDoNotUpgradeWithoutOriginCapacity() async {
        let low = makeVariant(name: "low", bandwidth: 500_000)
        let high = makeVariant(name: "high", bandwidth: 2_000_000)
        for sample in [nil, makeSample(600_000)] {
            let controller = AdaptiveVariantController()
            await controller.updateVariants([low, high])
            let decision = await controller.evaluate(
                currentVariant: low, qualityPolicy: .automatic,
                throughputSample: sample,
                bufferState: makeBufferState(playedSequence: nil),
                adaptationMode: .nativeVariants
            )
            XCTAssertEqual(decision.action, .hold)
            XCTAssertEqual(decision.targetVariant, low)
        }
    }

}
