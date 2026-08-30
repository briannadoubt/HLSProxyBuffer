import Foundation
import XCTest
@testable import HLSProxyFeedDemo
import HLSCore
@testable import ProxyPlayerKit

@MainActor
final class HLSProxyFeedDemoTests: XCTestCase {
    func testVerticalQualificationReportIsBoundedSanitizedAndCoversEveryMetric() throws {
        let telemetry = HLSFeedTelemetry(configuration: .init(
            latencyUpperBounds: [0.05, 0.1, 0.25],
            eventBufferCapacity: 2,
            maximumSubscriberCount: 1
        ))
        let path = HLSFeedTelemetry.Path(
            reuse: .warm,
            intent: .focused,
            mediaKind: .videoOnDemand
        )
        telemetry.record(.init(path: path, payload: .firstFrame(latency: 0.04)))
        telemetry.record(.init(path: path, payload: .stall(duration: 0.02)))
        telemetry.record(.init(
            path: path,
            payload: .cache(hits: 3, misses: 1, originBytesAvoided: 4_096)
        ))
        telemetry.record(.init(
            path: path,
            payload: .network(originRequests: 2, originBytesFetched: 8_192)
        ))
        telemetry.record(.init(
            path: path,
            payload: .cancellation(latency: 0.03, outcome: .acknowledged)
        ))
        telemetry.record(.init(
            path: path,
            payload: .handoff(wasReady: true, succeeded: true)
        ))
        telemetry.record(.init(payload: .resources(
            memoryBytes: 8_192,
            diskBytes: 16_384,
            playerPoolOccupancy: 2,
            proxyPoolOccupancy: 2
        )))
        telemetry.record(.init(payload: .cacheResources(
            memoryEntryCount: 1,
            diskEntryCount: 2,
            evictionCounts: [.memoryPressure: 1]
        )))

        let focused: FeedItemID = "fixture-focus"
        let generation = FeedNavigationGeneration(rawValue: 7)
        let engine = HLSFeedEngineSnapshot(
            generation: generation,
            targetFocusedItemID: focused,
            activeItemID: focused,
            audibleItemID: focused,
            requestedDestinationItemID: nil,
            playbacks: [HLSFeedPlayback(
                itemID: focused,
                generation: generation,
                role: .focused,
                phase: .focused,
                state: PlayerState(status: .ready),
                hasStartedPlayback: true,
                isAudible: true
            )],
            failures: [],
            poolOccupancy: 1,
            allocatedPlayerCount: 1,
            activeLoadCount: 0,
            maximumObservedPoolOccupancy: 2,
            maximumObservedAudiblePlaybackCount: 1,
            staleCompletionCount: 0,
            isPlaybackSuspended: false
        )
        let origin = FeedDemoFixtureOrigin.Snapshot(
            requestCount: 4,
            responseByteCount: 12_288,
            conditionalRequestCount: 1,
            notModifiedCount: 1,
            failureCount: 0,
            offlineRequestCount: 0,
            activeRequestCount: 0,
            maximumActiveRequestCount: 2,
            requestsByPath: ["https://forbidden.invalid/path": 1],
            bytesByPath: ["authorization": 1],
            records: []
        )
        let report = FeedDemoVerticalQualificationReport.make(
            focusedItemID: focused,
            engine: engine,
            telemetry: telemetry.snapshot,
            origin: origin,
            policy: .preset(.shortFormFeed),
            networkConditionTransitionCount: 3,
            memoryPressureActionCount: 1,
            backgroundTransitionCount: 1,
            foregroundTransitionCount: 1
        )

        XCTAssertTrue(report.passed, report.failureCodes.joined(separator: ", "))
        XCTAssertEqual(report.qualificationKind, "vertical_paging_ui")
        XCTAssertEqual(report.scenarioIDs.count, 8)
        XCTAssertEqual(
            report.evictionCounts.map(\.reason),
            HLSFeedTelemetry.CacheEvictionReason.allCases
        )
        XCTAssertEqual(report.firstFrameLatency.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(report.cancellationLatency.maximumMilliseconds),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(report.cacheHitBytes, 4_096)
        XCTAssertEqual(report.originByteCount, 8_192)
        XCTAssertEqual(report.fixtureResponseByteCount, 12_288)

        let json = report.json
        XCTAssertTrue(json.contains("\"passed\":true"))
        for forbidden in [
            "http://", "https://", "authorization", "cookie", "bearer",
            "requestHeaders", "responseHeaders", "fixture-focus",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                FeedDemoVerticalQualificationReport.self,
                from: Data(json.utf8)
            ),
            report
        )
    }

    func testPrimaryShortFormCatalogHasTwentyFourStableDistinctHLSItems() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .synthetic)
        let baseURL = try await origin.start()
        defer { origin.stop() }

        let entries = try FeedDemoCatalog.entries(for: .shortForm, baseURL: baseURL, library: nil)
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
        let origin = try FeedDemoFixtureOrigin(configuration: .synthetic)
        let baseURL = try await origin.start()
        defer { origin.stop() }

        for mode in FeedDemoMode.allCases {
            let entries = try FeedDemoCatalog.entries(for: mode, baseURL: baseURL, library: nil)
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
        let origin = try FeedDemoFixtureOrigin(configuration: .synthetic)
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

    func testFixtureOriginHeadAdvertisesFullLengthWithoutBodyAndIgnoresRange() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .synthetic)
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = baseURL.appendingPathComponent("short-a/segment-000.m4s")
        let (getData, getResponse) = try await session.data(from: url)
        let get = try XCTUnwrap(getResponse as? HTTPURLResponse)
        XCTAssertGreaterThan(getData.count, 0)
        for range in [nil, "bytes=0-31"] as [String?] {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            let head = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(head.statusCode, 200)
            XCTAssertEqual(head.value(forHTTPHeaderField: "Content-Length"), String(getData.count))
            XCTAssertEqual(head.value(forHTTPHeaderField: "ETag"), get.value(forHTTPHeaderField: "ETag"))
            XCTAssertNil(head.value(forHTTPHeaderField: "Content-Range"))
            XCTAssertTrue(data.isEmpty)
        }
        let accounting = await origin.snapshot()
        XCTAssertEqual(accounting.responseByteCount, getData.count)
        XCTAssertEqual(accounting.records.suffix(2).map(\.responseBytes), [0, 0])
    }

    func testFixtureOriginControlsFaultsOfflinePoorNetworkAndRequestAccounting() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .synthetic)
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
        let origin = try FeedDemoFixtureOrigin(configuration: .synthetic)
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

    func testModernScrollGeometryIsCoarsenedAndProjectsOnlyABoundedWindow() throws {
        let itemIDs = (0..<12).map { FeedItemID(rawValue: "item-\($0)") }
        let sample = FeedDemoScrollGeometrySample(
            contentOffsetY: 460,
            viewportSize: CGSize(width: 200, height: 100)
        )
        let frames = FeedDemoScrollGeometryProjector.frames(
            itemIDs: itemIDs,
            focusedItemID: itemIDs[0],
            sample: sample,
            itemsBehind: 2,
            itemsAhead: 2
        )

        XCTAssertEqual(sample.pageOffset, 4.6, accuracy: 0.0001)
        XCTAssertEqual(frames.count, 8)
        XCTAssertEqual(try XCTUnwrap(frames[itemIDs[4]]).minY, -60, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(frames[itemIDs[5]]).minY, 40, accuracy: 0.0001)
        XCTAssertNotNil(frames[itemIDs[0]], "The previous focus stays measurable during a fling")

        let zeroHeight = FeedDemoScrollGeometrySample(
            contentOffsetY: 100,
            viewportSize: CGSize(width: 200, height: 0)
        )
        XCTAssertEqual(zeroHeight.pageOffset, 0)
        XCTAssertTrue(FeedDemoScrollGeometryProjector.frames(
            itemIDs: itemIDs,
            focusedItemID: nil,
            sample: zeroHeight,
            itemsBehind: 2,
            itemsAhead: 2
        ).isEmpty)
    }

    func testProjectedScrollGeometryDrivesFastForwardAndReversePrediction() throws {
        let itemIDs = (0..<8).map { FeedItemID(rawValue: "item-\($0)") }
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        var builder = FeedDemoSignalBuilder(orderedItemIDs: itemIDs)

        func frames(pageOffset: CGFloat, focusedItemID: FeedItemID?) -> [FeedItemID: CGRect] {
            FeedDemoScrollGeometryProjector.frames(
                itemIDs: itemIDs,
                focusedItemID: focusedItemID,
                sample: FeedDemoScrollGeometrySample(
                    contentOffsetY: pageOffset * 100,
                    viewportSize: viewport.size
                ),
                itemsBehind: 2,
                itemsAhead: 2
            )
        }

        let initial = try XCTUnwrap(builder.makeSignal(
            frames: frames(pageOffset: 2, focusedItemID: nil),
            viewport: viewport,
            observedAt: .zero
        ))
        XCTAssertEqual(initial.focusedItemID, itemIDs[2])

        let forward = try XCTUnwrap(builder.makeSignal(
            frames: frames(pageOffset: 3.2, focusedItemID: itemIDs[2]),
            viewport: viewport,
            observedAt: .milliseconds(100)
        ))
        XCTAssertEqual(forward.focusedItemID, itemIDs[3])
        XCTAssertGreaterThan(forward.velocityInViewportsPerSecond, 2)
        XCTAssertEqual(forward.predictedDestinations.first?.itemID, itemIDs[4])

        let reversed = try XCTUnwrap(builder.makeSignal(
            frames: frames(pageOffset: 2.1, focusedItemID: itemIDs[3]),
            viewport: viewport,
            observedAt: .milliseconds(200)
        ))
        XCTAssertEqual(reversed.focusedItemID, itemIDs[2])
        XCTAssertLessThan(reversed.velocityInViewportsPerSecond, -2)
        XCTAssertEqual(reversed.predictedDestinations.first?.itemID, itemIDs[1])
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
        let model = FeedDemoModel(mediaConfiguration: .synthetic)
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

    func testBackgroundSchedulerRegistersSubmitsAndCancelsTypedRequests() throws {
        let scheduler = RecordingBackgroundScheduler()
        scheduler.deniedKinds = [.processing]
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let lifecycle = FeedDemoBackgroundLifecycle(
            scheduler: scheduler,
            policy: .shortFormFeed,
            now: { anchor }
        )

        lifecycle.recordRegistration(.refresh, accepted: true)
        lifecycle.recordRegistration(.processing, accepted: false)
        lifecycle.scheduleAll()

        XCTAssertEqual(lifecycle.snapshot.count(for: .registered), 1)
        XCTAssertEqual(lifecycle.snapshot.count(for: .registrationDenied), 1)
        XCTAssertEqual(lifecycle.snapshot.count(for: .scheduled), 1)
        XCTAssertEqual(lifecycle.snapshot.count(for: .systemDenied), 1)
        XCTAssertEqual(scheduler.requests.map(\.kind), [.refresh, .processing])
        XCTAssertEqual(
            scheduler.requests[0].earliestBeginDate,
            anchor.addingTimeInterval(15 * 60)
        )
        XCTAssertFalse(scheduler.requests[0].requiresNetworkConnectivity)
        XCTAssertEqual(
            scheduler.requests[1].earliestBeginDate,
            anchor.addingTimeInterval(60 * 60)
        )
        XCTAssertTrue(scheduler.requests[1].requiresNetworkConnectivity)
        XCTAssertTrue(scheduler.requests.allSatisfy { !$0.requiresExternalPower })

        lifecycle.cancelPending()
        XCTAssertEqual(scheduler.cancelledKinds, [.refresh, .processing])
    }

    func testBackgroundLifecycleRecordsBoundedSanitizedTerminalOutcomes() async throws {
        let scheduler = RecordingBackgroundScheduler()
        let lifecycle = FeedDemoBackgroundLifecycle(scheduler: scheduler)
        let request = try backgroundRequest(candidateCount: 2)

        let completed = await lifecycle.run(kind: .refresh, request: request) {
            FeedDemoBackgroundWorkResult(outcome: .completed, admittedItemCount: 2)
        }
        let denied = await lifecycle.run(kind: .processing, request: request) {
            FeedDemoBackgroundWorkResult(outcome: .policyDenied, admittedItemCount: 0)
        }

        XCTAssertTrue(completed)
        XCTAssertTrue(denied)
        XCTAssertEqual(lifecycle.snapshot.count(for: .admitted), 2)
        XCTAssertEqual(lifecycle.snapshot.count(for: .completed), 1)
        XCTAssertEqual(lifecycle.snapshot.count(for: .policyDenied), 1)
        XCTAssertEqual(lifecycle.snapshot.maximumCandidateCount, 2)
        XCTAssertEqual(lifecycle.snapshot.maximumAdmittedItemCount, 2)
        XCTAssertNil(lifecycle.snapshot.activeTaskKind)

        let json = String(
            decoding: try lifecycle.machineReadableSummary(),
            as: UTF8.self
        )
        XCTAssertFalse(json.contains("fixture.invalid"))
        XCTAssertFalse(json.contains("item-"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("url"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("identifier"))
    }

    func testBackgroundExpirationCancelsWorkAndIsNotReportedAsGenericCancellation() async throws {
        let lifecycle = FeedDemoBackgroundLifecycle(
            scheduler: RecordingBackgroundScheduler()
        )
        let request = try backgroundRequest(candidateCount: 1)
        let run = Task { @MainActor in
            await lifecycle.run(kind: .processing, request: request) {
                try await ContinuousClock().sleep(for: .seconds(30))
                return FeedDemoBackgroundWorkResult(
                    outcome: .completed,
                    admittedItemCount: 1
                )
            }
        }

        while lifecycle.snapshot.activeTaskKind == nil {
            await Task.yield()
        }
        lifecycle.expire(.processing)

        let succeeded = await run.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(lifecycle.snapshot.count(for: .expired), 1)
        XCTAssertEqual(lifecycle.snapshot.count(for: .cancelled), 0)
        XCTAssertNil(lifecycle.snapshot.activeTaskKind)
    }

    func testDemoBackgroundTransitionSilencesPlaybackResubmitsAndHonorsWarmCap() async {
        let scheduler = RecordingBackgroundScheduler()
        let environment = FeedDemoStaticBackgroundEnvironment(current: .init(
            networkInterface: .wifi
        ))
        let model = FeedDemoModel(
            mediaConfiguration: .synthetic,
            backgroundScheduler: scheduler,
            backgroundEnvironment: environment
        )
        await model.start()
        XCTAssertEqual(model.status, .running)

        model.handleApplicationPhase(.background)
        XCTAssertTrue(model.engine?.snapshot.isPlaybackSuspended == true)
        XCTAssertNil(model.engine?.snapshot.audibleItemID)
        XCTAssertEqual(scheduler.requests.map(\.kind), [.refresh, .processing])

        _ = await model.performBackgroundTask(.refresh)
        XCTAssertEqual(scheduler.requests.map(\.kind), [.refresh, .processing, .refresh])
        XCTAssertLessThanOrEqual(
            model.backgroundSnapshot.maximumCandidateCount,
            HLSFeedBackgroundWarmingPolicy.shortFormFeed.maximumItemCount
        )
        XCTAssertLessThanOrEqual(
            model.backgroundSnapshot.maximumAdmittedItemCount,
            HLSFeedBackgroundWarmingPolicy.shortFormFeed.maximumItemCount
        )
        XCTAssertNil(model.engine?.snapshot.audibleItemID)

        model.handleApplicationPhase(.active)
        XCTAssertTrue(model.engine?.snapshot.isPlaybackSuspended == false)
        XCTAssertEqual(scheduler.cancelledKinds, [.refresh, .processing])
        await model.stop()
    }

    private func backgroundRequest(
        candidateCount: Int
    ) throws -> HLSFeedBackgroundWarmingRequest {
        HLSFeedBackgroundWarmingRequest(
            candidates: try (0..<candidateCount).map { index in
                HLSFeedBackgroundWarmingCandidate(item: FeedPlaybackItem(
                    id: .init(rawValue: "item-\(index)"),
                    source: .stream(
                        url: try XCTUnwrap(
                            URL(string: "https://fixture.invalid/\(index).m3u8")
                        ),
                        kind: .videoOnDemand
                    ),
                    estimatedPreparationBytes: 1_024
                ))
            },
            environment: .init(networkInterface: .wifi),
            availableExecutionTime: .seconds(15)
        )
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

@MainActor
private final class RecordingBackgroundScheduler: FeedDemoBackgroundScheduling {
    var deniedKinds: Set<FeedDemoBackgroundTaskKind> = []
    private(set) var requests: [FeedDemoBackgroundScheduleRequest] = []
    private(set) var cancelledKinds: [FeedDemoBackgroundTaskKind] = []

    func submit(_ request: FeedDemoBackgroundScheduleRequest) throws {
        requests.append(request)
        if deniedKinds.contains(request.kind) {
            throw FeedDemoUnavailableBackgroundScheduler.Unavailable()
        }
    }

    func cancel(_ kind: FeedDemoBackgroundTaskKind) {
        cancelledKinds.append(kind)
    }
}
