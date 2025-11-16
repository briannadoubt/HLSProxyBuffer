import XCTest
@testable import HLSCore

final class ThroughputEstimatorTests: XCTestCase {
    func testMaintainsSteadyEstimate() async {
        let estimator = ThroughputEstimator(configuration: .init(window: 4))
        let url = URL(string: "https://example.com/segment.ts")!
        let metrics = HLSSegmentFetcher.FetchMetrics(url: url, byteCount: 500_000, duration: 1)

        for index in 0..<8 {
            await estimator.ingest(metrics, at: Date(timeIntervalSince1970: Double(index)))
        }

        let sample = await estimator.sample()
        XCTAssertEqual(sample?.bitsPerSecond ?? 0, 4_000_000, accuracy: 50_000)
        XCTAssertEqual(sample?.lastSampleDate, Date(timeIntervalSince1970: 7))
    }

    func testRespondsToStepChange() async {
        let estimator = ThroughputEstimator(configuration: .init(window: 3))
        let url = URL(string: "https://example.com/segment.ts")!

        let fast = HLSSegmentFetcher.FetchMetrics(url: url, byteCount: 500_000, duration: 1)
        let slow = HLSSegmentFetcher.FetchMetrics(url: url, byteCount: 500_000, duration: 4)

        for index in 0..<5 {
            await estimator.ingest(fast, at: Date(timeIntervalSince1970: Double(index)))
        }

        let initial = await estimator.sample()
        XCTAssertNotNil(initial)
        XCTAssertGreaterThan(initial!.bitsPerSecond, 3_500_000)

        for index in 5..<8 {
            await estimator.ingest(slow, at: Date(timeIntervalSince1970: Double(index)))
        }

        let adjusted = await estimator.sample()
        XCTAssertNotNil(adjusted)
        XCTAssertLessThan(adjusted!.bitsPerSecond, 2_200_000)
        XCTAssertEqual(adjusted!.lastSampleDate, Date(timeIntervalSince1970: 7))
    }

    func testResetClearsSample() async {
        let estimator = ThroughputEstimator(configuration: .init(window: 3))
        let url = URL(string: "https://example.com/segment.ts")!
        let metrics = HLSSegmentFetcher.FetchMetrics(url: url, byteCount: 500_000, duration: 1)

        await estimator.ingest(metrics, at: Date())
        let sampleBeforeReset = await estimator.sample()
        XCTAssertNotNil(sampleBeforeReset)

        await estimator.reset()
        let sampleAfterReset = await estimator.sample()
        XCTAssertNil(sampleAfterReset)
    }
}
