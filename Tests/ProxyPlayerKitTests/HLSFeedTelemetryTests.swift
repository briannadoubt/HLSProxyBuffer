import Foundation
import Observation
import XCTest
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedTelemetryTests: XCTestCase {
    func testOneHundredThousandEventsKeepFixedStorageAndCorrectAggregates() throws {
        let telemetry = HLSFeedTelemetry(configuration: .init(
            latencyUpperBounds: [0.1, 1],
            eventBufferCapacity: 2,
            maximumSubscriberCount: 1
        ))
        let path = HLSFeedTelemetry.Path(
            reuse: .cold,
            intent: .focused,
            mediaKind: .videoOnDemand
        )

        for index in 0..<100_000 {
            let event: HLSFeedTelemetry.Event
            switch index % 5 {
            case 0:
                event = .init(path: path, payload: .firstFrame(latency: 0.01))
            case 1:
                event = .init(path: path, payload: .firstFrame(latency: 0.2))
            case 2:
                event = .init(path: path, payload: .stall(duration: 0.75))
            case 3:
                event = .init(
                    path: path,
                    payload: .cancellation(latency: 0.05, outcome: .acknowledged)
                )
            default:
                event = .init(
                    path: path,
                    payload: .cache(hits: 3, misses: 1, originBytesAvoided: 100)
                )
            }
            telemetry.record(event)
        }

        let snapshot = telemetry.snapshot
        let metrics = try XCTUnwrap(snapshot.metrics(for: path))
        XCTAssertEqual(snapshot.eventCount, 100_000)
        XCTAssertEqual(snapshot.paths.count, 12)
        XCTAssertEqual(snapshot.storageBound.pathCount, 12)
        XCTAssertEqual(snapshot.storageBound.histogramCount, 36)
        XCTAssertEqual(snapshot.storageBound.bucketsPerHistogram, 3)
        XCTAssertEqual(snapshot.storageBound.maximumHistogramBucketCount, 108)
        XCTAssertEqual(snapshot.storageBound.maximumCancellationOutcomeCount, 36)
        XCTAssertEqual(snapshot.storageBound.maximumBufferedEventCount, 2)
        XCTAssertEqual(metrics.firstFrameLatency.bucketCounts, [20_000, 20_000, 0])
        XCTAssertEqual(metrics.firstFrameLatency.count, 40_000)
        XCTAssertEqual(metrics.firstFrameLatency.approximateQuantile(0.5), 0.1)
        XCTAssertEqual(metrics.firstFrameLatency.approximateQuantile(0.95), 1)
        XCTAssertEqual(metrics.stallDuration.count, 20_000)
        XCTAssertEqual(metrics.cancellationLatency.count, 20_000)
        XCTAssertEqual(metrics.cancellationOutcomeCounts[.acknowledged], 20_000)
        XCTAssertEqual(metrics.cacheHitCount, 60_000)
        XCTAssertEqual(metrics.cacheMissCount, 20_000)
        XCTAssertEqual(try XCTUnwrap(metrics.cacheHitRate), 0.75, accuracy: 0.0001)
        XCTAssertEqual(metrics.originBytesAvoided, 2_000_000)
    }

    func testSlowConsumerDropsOldestEventsAndCountsEveryDrop() async throws {
        let telemetry = HLSFeedTelemetry(configuration: .init(
            latencyUpperBounds: [1],
            eventBufferCapacity: 2,
            maximumSubscriberCount: 1
        ))
        let path = HLSFeedTelemetry.Path(
            reuse: .warm,
            intent: .predicted,
            mediaKind: .live
        )
        var iterator = telemetry.events().makeAsyncIterator()
        var rejectedIterator = telemetry.events().makeAsyncIterator()

        for value in 1...5 {
            telemetry.record(.init(
                path: path,
                payload: .firstFrame(latency: TimeInterval(value))
            ))
        }

        let firstValue = await iterator.next()
        let secondValue = await iterator.next()
        let rejectedValue = await rejectedIterator.next()
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(first.payload, .firstFrame(latency: 4))
        XCTAssertEqual(second.payload, .firstFrame(latency: 5))
        XCTAssertNil(rejectedValue)
        XCTAssertEqual(telemetry.snapshot.droppedEventCount, 3)
        XCTAssertEqual(telemetry.snapshot.rejectedSubscriberCount, 1)
        XCTAssertEqual(telemetry.snapshot.activeSubscriberCount, 1)
    }

    func testResourcesTrackCurrentAndMaximumResidencyAndPoolOccupancy() {
        let telemetry = HLSFeedTelemetry()

        telemetry.record(.init(payload: .resources(
            memoryBytes: 4_096,
            diskBytes: 16_384,
            playerPoolOccupancy: 3,
            proxyPoolOccupancy: 2
        )))
        telemetry.record(.init(payload: .resources(
            memoryBytes: 1_024,
            diskBytes: 8_192,
            playerPoolOccupancy: 1,
            proxyPoolOccupancy: 1
        )))

        XCTAssertEqual(telemetry.snapshot.resources.memoryResidentBytes, 1_024)
        XCTAssertEqual(telemetry.snapshot.resources.maximumMemoryResidentBytes, 4_096)
        XCTAssertEqual(telemetry.snapshot.resources.diskResidentBytes, 8_192)
        XCTAssertEqual(telemetry.snapshot.resources.maximumDiskResidentBytes, 16_384)
        XCTAssertEqual(telemetry.snapshot.resources.playerPoolOccupancy, 1)
        XCTAssertEqual(telemetry.snapshot.resources.maximumPlayerPoolOccupancy, 3)
        XCTAssertEqual(telemetry.snapshot.resources.proxyPoolOccupancy, 1)
        XCTAssertEqual(telemetry.snapshot.resources.maximumProxyPoolOccupancy, 2)
    }

    func testPathMatrixDistinguishesWarmColdFocusedPredictedLiveAndStitched() throws {
        let telemetry = HLSFeedTelemetry()
        let coldFocusedVOD = HLSFeedTelemetry.Path(
            reuse: .cold,
            intent: .focused,
            mediaKind: .videoOnDemand
        )
        let warmPredictedLive = HLSFeedTelemetry.Path(
            reuse: .warm,
            intent: .predicted,
            mediaKind: .live
        )
        let warmFocusedStitched = HLSFeedTelemetry.Path(
            reuse: .warm,
            intent: .focused,
            mediaKind: .stitched
        )

        telemetry.record(.init(path: coldFocusedVOD, payload: .firstFrame(latency: 0.4)))
        telemetry.record(.init(
            path: warmPredictedLive,
            payload: .cache(hits: 4, misses: 0, originBytesAvoided: 8_192)
        ))
        telemetry.record(.init(
            path: warmFocusedStitched,
            payload: .handoff(wasReady: true, succeeded: true)
        ))

        XCTAssertEqual(
            telemetry.snapshot.metrics(for: coldFocusedVOD)?.firstFrameLatency.count,
            1
        )
        XCTAssertEqual(
            telemetry.snapshot.metrics(for: warmPredictedLive)?.cacheHitCount,
            4
        )
        XCTAssertEqual(
            telemetry.snapshot.metrics(for: warmFocusedStitched)?.handoffSuccessCount,
            1
        )
        let data = try telemetry.machineReadableSummary()
        let decoded = try JSONDecoder().decode(HLSFeedTelemetry.Snapshot.self, from: data)
        XCTAssertEqual(decoded, telemetry.snapshot)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("originBytesAvoided"))
    }

    func testSnapshotParticipatesInObservation() async {
        let telemetry = HLSFeedTelemetry()
        let changed = expectation(description: "Observation saw telemetry snapshot change")
        withObservationTracking {
            _ = telemetry.snapshot.eventCount
        } onChange: {
            changed.fulfill()
        }

        telemetry.record(.init(payload: .resources(
            memoryBytes: 1,
            diskBytes: 2,
            playerPoolOccupancy: 1,
            proxyPoolOccupancy: 1
        )))

        await fulfillment(of: [changed], timeout: 1)
    }

    func testConfigurationCapsEveryCollectionDimension() {
        let telemetry = HLSFeedTelemetry(configuration: .init(
            latencyUpperBounds: Array(1...100).map(TimeInterval.init),
            eventBufferCapacity: 10_000,
            maximumSubscriberCount: 1_000
        ))

        XCTAssertEqual(telemetry.snapshot.storageBound.bucketsPerHistogram, 33)
        XCTAssertEqual(telemetry.snapshot.storageBound.maximumSubscriberCount, 8)
        XCTAssertEqual(telemetry.snapshot.storageBound.eventBufferCapacityPerSubscriber, 256)
        XCTAssertEqual(telemetry.snapshot.storageBound.maximumBufferedEventCount, 2_048)
    }
}
