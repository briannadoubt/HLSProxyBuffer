import Foundation
import XCTest
@testable import HLSProxyFeedDemo
import HLSCore
import ProxyPlayerKit

@MainActor
final class HLSProxyFeedDemoTests: XCTestCase {
    func testPrimaryShortFormCatalogHasTwentyFourStableDistinctHLSItems() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }

        let entries = FeedDemoCatalog.entries(for: .shortForm, baseURL: baseURL)
        XCTAssertEqual(entries.count, 24)
        XCTAssertEqual(Set(entries.map(\.id)).count, 24)
        let urls = entries.compactMap { entry -> URL? in
            guard case .stream(let url, .videoOnDemand) = entry.item.source else { return nil }
            return url
        }
        XCTAssertEqual(Set(urls).count, 24)
        XCTAssertTrue(urls.allSatisfy { $0.path.hasPrefix("/feed/feed-") })

        let parser = HLSParser()
        var observedSegmentCounts: Set<Int> = []
        var observedFixtureIDs: Set<String> = []
        for url in urls {
            let (data, response) = try await URLSession.shared.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            observedFixtureIDs.insert(try XCTUnwrap(
                http.value(forHTTPHeaderField: "X-HLS-Fixture-Item")
            ))
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let manifest = try parser.parse(text, baseURL: url)
            observedSegmentCounts.insert(try XCTUnwrap(manifest.mediaPlaylist).segments.count)
        }
        XCTAssertEqual(observedFixtureIDs.count, 24)
        XCTAssertEqual(observedSegmentCounts, [2, 3])
    }

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

    func testFixtureOriginControlsFaultsOfflinePoorNetworkAndRequestAccounting() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let segmentPath = "/feed/feed-01/segment-000.m4s"
        let segmentURL = baseURL.appendingPathComponent(String(segmentPath.dropFirst()))
        await origin.setNetworkProfile(.init(
            responseDelay: .milliseconds(20),
            bytesPerSecond: 2_000
        ))
        await origin.setFaults([.init(
            path: segmentPath,
            attempts: 1...1,
            action: .serviceUnavailable
        )])

        var request = URLRequest(url: segmentURL)
        request.setValue("bytes=0-199", forHTTPHeaderField: "Range")
        let (_, failedResponse) = try await session.data(for: request)
        XCTAssertEqual((failedResponse as? HTTPURLResponse)?.statusCode, 503)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let (segmentData, successfulResponse) = try await session.data(for: request)
        let elapsed = clock.now - startedAt
        XCTAssertEqual((successfulResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(segmentData.count, 200)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100))

        let playlistURL = baseURL.appendingPathComponent("feed/feed-01/playlist.m3u8")
        let (_, playlistResponse) = try await session.data(from: playlistURL)
        let etag = try XCTUnwrap(
            (playlistResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        )
        var validationRequest = URLRequest(url: playlistURL)
        validationRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let (validationData, validationResponse) = try await session.data(
            for: validationRequest
        )
        XCTAssertEqual((validationResponse as? HTTPURLResponse)?.statusCode, 304)
        XCTAssertTrue(validationData.isEmpty)

        await origin.setOffline(true)
        var offlineRequest = URLRequest(url: playlistURL)
        offlineRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, offlineResponse) = try await session.data(for: offlineRequest)
        XCTAssertEqual((offlineResponse as? HTTPURLResponse)?.statusCode, 503)

        let snapshot = await origin.snapshot()
        XCTAssertEqual(snapshot.requestCount, 5)
        XCTAssertEqual(snapshot.requestsByPath[segmentPath], 2)
        XCTAssertEqual(snapshot.bytesByPath[segmentPath], 200)
        XCTAssertEqual(snapshot.conditionalRequestCount, 1)
        XCTAssertEqual(snapshot.notModifiedCount, 1)
        XCTAssertEqual(snapshot.offlineRequestCount, 1)
        XCTAssertEqual(snapshot.failureCount, 2)
        XCTAssertEqual(snapshot.records.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertTrue(snapshot.records.allSatisfy { $0.feedItemID == "feed-01" })
        let encodedSnapshot = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(FeedDemoFixtureOrigin.Snapshot.self, from: encodedSnapshot),
            snapshot
        )

        await origin.resetRequestAccounting()
        let resetSnapshot = await origin.snapshot()
        XCTAssertEqual(resetSnapshot, .empty)
    }

    func testFixtureOriginAccountsForConcurrentFeedItemsIndependently() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }
        await origin.setNetworkProfile(.init(responseDelay: .milliseconds(100)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let urls = (1...3).map { index in
            baseURL.appendingPathComponent(String(format: "feed/feed-%02d/playlist.m3u8", index))
        }

        async let first = session.data(from: urls[0])
        async let second = session.data(from: urls[1])
        async let third = session.data(from: urls[2])
        let responses = try await [first, second, third]
        XCTAssertTrue(responses.allSatisfy {
            ($0.1 as? HTTPURLResponse)?.statusCode == 200 && !$0.0.isEmpty
        })

        let snapshot = await origin.snapshot()
        XCTAssertEqual(snapshot.requestCount, 3)
        XCTAssertGreaterThanOrEqual(snapshot.maximumActiveRequestCount, 3)
        XCTAssertEqual(Set(snapshot.records.compactMap(\.feedItemID)).count, 3)
        XCTAssertEqual(snapshot.requestsByPath.count, 3)
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
