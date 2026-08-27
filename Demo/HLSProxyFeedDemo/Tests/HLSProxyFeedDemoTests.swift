import Foundation
import XCTest
@testable import HLSProxyFeedDemo
import ProxyPlayerKit

@MainActor
final class HLSProxyFeedDemoTests: XCTestCase {
    func testEveryModeUsesAValidatedPolicyAndLocalFixtureCatalog() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }

        for mode in FeedDemoMode.allCases {
            let entries = FeedDemoCatalog.entries(for: mode, baseURL: baseURL)
            XCTAssertFalse(entries.isEmpty, "\(mode) must have a runnable fixture catalog")
            XCTAssertNoThrow(try mode.policy.validated())
            XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)

            let engine = try HLSFeedEngine(
                items: entries.map(\.item),
                policy: mode.policy,
                sourceTransportPolicy: .allowLoopbackHTTP
            )
            let first = try XCTUnwrap(entries.first)
            let initial = try await engine.update(FeedViewportSignal(
                generation: .init(rawValue: 1),
                focusedItemID: first.id,
                visibleItems: [.init(
                    itemID: first.id,
                    fraction: 1,
                    distanceInViewports: 0
                )],
                observedAt: .zero
            ))
            XCTAssertEqual(initial.targetFocusedItemID, first.id, "\(mode)")
            XCTAssertTrue(initial.failures.isEmpty, "\(mode): \(initial.failures)")
            await engine.stop()
        }
    }

    func testFixtureOriginServesByteRangesAndValidators() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let url = baseURL
            .appendingPathComponent("short-a", isDirectory: true)
            .appendingPathComponent("segment-000.m4s")
        var request = URLRequest(url: url)
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertNotNil(http.value(forHTTPHeaderField: "ETag"))
    }

    func testGeometrySignalsChooseFocusDeterministicallyAndPredictDirection() throws {
        let itemIDs: [FeedItemID] = ["a", "b", "c"]
        var builder = FeedDemoSignalBuilder(orderedItemIDs: itemIDs)
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let initial = try XCTUnwrap(builder.makeSignal(
            frames: [
                itemIDs[0]: CGRect(x: 0, y: 0, width: 100, height: 100),
                itemIDs[1]: CGRect(x: 0, y: 100, width: 100, height: 100),
            ],
            viewport: viewport,
            observedAt: .zero
        ))
        XCTAssertEqual(initial.focusedItemID, itemIDs[0])
        XCTAssertEqual(initial.generation.rawValue, 1)

        let advanced = try XCTUnwrap(builder.makeSignal(
            frames: [
                itemIDs[0]: CGRect(x: 0, y: -60, width: 100, height: 100),
                itemIDs[1]: CGRect(x: 0, y: 40, width: 100, height: 100),
                itemIDs[2]: CGRect(x: 0, y: 140, width: 100, height: 100),
            ],
            viewport: viewport,
            observedAt: .milliseconds(100)
        ))
        XCTAssertEqual(advanced.focusedItemID, itemIDs[1])
        XCTAssertEqual(advanced.generation.rawValue, 2)
        XCTAssertGreaterThan(advanced.velocityInViewportsPerSecond, 0)
        XCTAssertEqual(advanced.predictedDestinations.first?.itemID, itemIDs[2])
    }

    func testAnalyticsInspectorBoundsTypedRowsAndSanitizedCanonicalPreview() async throws {
        let inspector = FeedDemoAnalyticsInspector()
        let sources: [PlaybackAnalytics.Source] = [
            .avFoundation,
            .localProxy,
            .feedEngine,
            .exporter,
        ]
        let correlation = PlaybackAnalytics.Correlation(
            sessionID: .init(),
            playbackID: .init(),
            itemID: .init()
        )
        let anchor = PlaybackAnalytics.ClockAnchor(unixMilliseconds: 1_700_000_000_000)

        for index in 0..<25 {
            let event = try PlaybackAnalytics.Event(
                correlation: correlation,
                timestamp: .init(
                    anchor: anchor,
                    elapsedNanoseconds: UInt64(index) * 1_000_000
                ),
                source: sources[index % sources.count],
                lifecycle: .resourceCompleted,
                measurements: [try .init(
                    name: .init("origin_bytes"),
                    value: Double(index),
                    unit: .bytes
                )]
            )
            inspector.record(event, timelineSnapshot: .empty)
        }

        XCTAssertEqual(
            inspector.recentEvents.count,
            FeedDemoAnalyticsInspector.maximumRecentEventCount
        )
        XCTAssertEqual(inspector.layerCounts[.avFoundation], 7)
        XCTAssertEqual(inspector.layerCounts[.proxyOrigin], 6)
        XCTAssertEqual(inspector.layerCounts[.engine], 6)
        XCTAssertEqual(inspector.layerCounts[.exporter], 6)
        XCTAssertLessThanOrEqual(
            inspector.exportPreviewBytes,
            FeedDemoAnalyticsInspector.maximumPreviewBytes
        )
        XCTAssertEqual(inspector.exportPreview.split(separator: "\n").count, 4)

        let summary = try PlaybackAnalytics.Summary(
            correlation: correlation,
            startedAt: .init(anchor: anchor, elapsedNanoseconds: 0),
            endedAt: .init(anchor: anchor, elapsedNanoseconds: 25_000_000),
            terminalReason: .completed,
            measurements: [try .init(
                name: .init("watch_duration"),
                value: 0.025,
                unit: .seconds
            )]
        )
        inspector.record(summary, timelineSnapshot: .empty)

        XCTAssertEqual(inspector.latestSummary?.terminalReason, "completed")
        XCTAssertEqual(inspector.latestSummary?.durationMilliseconds, 25)
        for forbidden in [
            "http://", "https://", "authorization", "cookie", "bearer", "token",
            "requestHeaders", "responseHeaders", "userIdentifier", "ipAddress",
        ] {
            XCTAssertFalse(
                inspector.exportPreview.localizedCaseInsensitiveContains(forbidden),
                "Preview leaked forbidden text: \(forbidden)"
            )
        }

        let sink = InMemoryPlaybackAnalyticsSink()
        let delivery = PlaybackAnalyticsDelivery(
            sink: sink,
            configuration: .init(flushInterval: .seconds(60))
        )
        await delivery.record(summary)
        await delivery.flush()
        inspector.update(delivery: await delivery.snapshot)
        XCTAssertEqual(inspector.deliveryHealth.deliveredRecordCount, 1)
        XCTAssertEqual(inspector.deliveryHealth.droppedRecordCount, 0)
        _ = await delivery.shutdown()
    }

    func testDemoAnalyticsPipelineCoversEveryPlaybackMode() async throws {
        let model = FeedDemoModel()
        await model.start()

        XCTAssertEqual(model.status, .running)
        for mode in FeedDemoMode.allCases {
            await model.select(mode)
            XCTAssertEqual(model.status, .running, "\(mode)")
            let didReceiveAnalytics = await waitForAnalytics(in: model, mode: mode)
            XCTAssertTrue(didReceiveAnalytics, "\(mode)")
            XCTAssertEqual(model.analyticsInspector.mode, mode)
            XCTAssertGreaterThan(model.analyticsInspector.emittedEventCount, 0, "\(mode)")
            XCTAssertGreaterThan(model.analyticsInspector.layerCounts[.engine], 0, "\(mode)")
            XCTAssertFalse(model.analyticsInspector.exportPreview.isEmpty, "\(mode)")
            XCTAssertLessThanOrEqual(
                model.analyticsInspector.recentEvents.count,
                FeedDemoAnalyticsInspector.maximumRecentEventCount,
                "\(mode)"
            )
        }
        await model.stop()
    }

    private func waitForAnalytics(
        in model: FeedDemoModel,
        mode: FeedDemoMode
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if model.analyticsInspector.mode == mode,
               model.analyticsInspector.emittedEventCount > 0,
               !model.analyticsInspector.exportPreview.isEmpty {
                return true
            }
            try? await clock.sleep(for: .milliseconds(25))
        }
        return false
    }
}
