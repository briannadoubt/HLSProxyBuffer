#if canImport(Network)
import Foundation
import XCTest
@testable import HLSCore
@testable import ProxyPlayerKit

final class FeedFixtureHarnessTests: XCTestCase {
    func testGeneratedFixturesAreRealOfflineHLSMedia() throws {
        let parser = HLSParser()
        let shortA = try mediaPlaylist(named: "short-a", parser: parser)
        let shortB = try mediaPlaylist(named: "short-b", parser: parser)
        let longForm = try mediaPlaylist(named: "long-form", parser: parser)
        let live = try mediaPlaylist(named: "live", parser: parser)

        XCTAssertEqual(shortA.segments.count, 3)
        XCTAssertEqual(shortB.segments.count, 3)
        XCTAssertEqual(longForm.segments.count, 8)
        XCTAssertTrue(shortA.isEndlist)
        XCTAssertTrue(shortB.isEndlist)
        XCTAssertTrue(longForm.isEndlist)
        XCTAssertFalse(live.isEndlist)
        XCTAssertEqual(live.mediaSequence, 105)
        XCTAssertEqual(live.segments.count, 3)
        XCTAssertNotNil(shortA.segments.first?.initializationMap)

        let shortAInit = try fixtureData("short-a/init.mp4")
        let shortBInit = try fixtureData("short-b/init.mp4")
        XCTAssertEqual(shortAInit, shortBInit, "stitched fixtures must share initialization state")
        XCTAssertEqual(String(data: shortAInit.subdata(in: 4..<8), encoding: .ascii), "ftyp")

        let fragment = try fixtureData("short-a/segment-000.m4s")
        XCTAssertNotNil(fragment.range(of: Data("moof".utf8)))
        XCTAssertNotNil(fragment.range(of: Data("mdat".utf8)))
    }

    func testOriginSupportsRangesValidatorsRetriesAndDisconnects() async throws {
        let origin = try FeedFixtureOrigin(profile: .init(faults: [
            .init(
                path: "/short-a/segment-000.m4s",
                attempts: 1...1,
                action: .serviceUnavailable
            ),
            .init(
                path: "/short-b/segment-000.m4s",
                attempts: 1...1,
                action: .disconnect(afterBodyBytes: 128)
            ),
        ]))
        try await origin.start()
        defer { origin.stop() }
        let session = makeSession()

        let playlistURL = origin.fixturePlaylistURL(named: "short-a")
        let (_, initialResponse) = try await session.data(from: playlistURL)
        let initialHTTPResponse = try XCTUnwrap(initialResponse as? HTTPURLResponse)
        let etag = try XCTUnwrap(initialHTTPResponse.value(forHTTPHeaderField: "ETag"))
        XCTAssertEqual(initialHTTPResponse.statusCode, 200)

        var validationRequest = URLRequest(url: playlistURL)
        validationRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let (validationData, validationResponse) = try await session.data(for: validationRequest)
        XCTAssertEqual((validationResponse as? HTTPURLResponse)?.statusCode, 304)
        XCTAssertTrue(validationData.isEmpty)

        var rangeRequest = URLRequest(url: origin.url(for: "/short-a/segment-001.m4s"))
        rangeRequest.setValue("bytes=10-109", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await session.data(for: rangeRequest)
        XCTAssertEqual((rangeResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(rangeData.count, 100)
        XCTAssertEqual(
            (rangeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
            "bytes 10-109/\(try fixtureData("short-a/segment-001.m4s").count)"
        )

        let retryURL = origin.url(for: "/short-a/segment-000.m4s")
        let (_, failedResponse) = try await session.data(from: retryURL)
        XCTAssertEqual((failedResponse as? HTTPURLResponse)?.statusCode, 503)
        let (retriedData, retriedResponse) = try await session.data(from: retryURL)
        XCTAssertEqual((retriedResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(retriedData.isEmpty)

        do {
            _ = try await session.data(from: origin.url(for: "/short-b/segment-000.m4s"))
            XCTFail("A deliberately disconnected response must not complete")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }

        let events = origin.timelineSnapshot()
        XCTAssertTrue(events.contains { $0.kind == .responseStarted && $0.statusCode == 304 })
        XCTAssertTrue(events.contains { $0.kind == .requestStarted && $0.requestedRange == "bytes=10-109" })
        XCTAssertEqual(
            events.filter { $0.path == "/short-a/segment-000.m4s" && $0.kind == .requestStarted }.map(\.attempt),
            [1, 2]
        )
        XCTAssertTrue(events.contains { $0.kind == .serverDisconnected })
    }

    func testOriginRecordsBandwidthConcurrencyBytesAndClientCancellation() async throws {
        let origin = try FeedFixtureOrigin(profile: .init(
            responseDelay: .milliseconds(100),
            bytesPerSecond: 2_000
        ))
        try await origin.start()
        defer { origin.stop() }
        let session = makeSession()

        func rangeRequest(_ path: String) -> URLRequest {
            var request = URLRequest(url: origin.url(for: path))
            request.setValue("bytes=0-299", forHTTPHeaderField: "Range")
            return request
        }

        async let first = session.data(for: rangeRequest("/short-a/segment-001.m4s"))
        async let second = session.data(for: rangeRequest("/short-b/segment-001.m4s"))
        let responses = try await [first, second]
        XCTAssertEqual(responses.map { $0.0.count }, [300, 300])

        let cancellationTask = Task {
            try await session.data(from: origin.url(for: "/long-form/segment-000.m4s"))
        }
        try await waitUntil {
            origin.timelineSnapshot().contains {
                $0.path == "/long-form/segment-000.m4s" && $0.kind == .requestStarted
            }
        }
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            XCTFail("The cancelled request must throw")
        } catch is CancellationError {
            // URLSession may bridge cancellation directly.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        try await waitUntil {
            origin.timelineSnapshot().contains {
                $0.path == "/long-form/segment-000.m4s" && $0.kind == .requestCancelled
            }
        }

        let events = origin.timelineSnapshot()
        XCTAssertGreaterThanOrEqual(events.map(\.activeRequests).max() ?? 0, 2)
        let byteEvents = events.filter { $0.kind == .responseBytes }
        XCTAssertGreaterThanOrEqual(byteEvents.count, 6)
        XCTAssertEqual(
            byteEvents.filter { $0.requestedRange == "bytes=0-299" }.reduce(0) { $0 + $1.bytes },
            600
        )
        XCTAssertTrue(events.contains { $0.kind == .requestCancelled })
    }

    func testStandardTraceCatalogReplaysMoreThanFiveHundredFocusChangesDeterministically() throws {
        let items = makeItems(count: 11)
        let traces = FeedNavigationTrace.standardCatalog(itemCount: items.count)
        let policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        let limits = try policy.makePlanningLimits()
        let replayer = FeedTraceReplayer(
            planner: FeedPlanner(limits: limits)
        )

        XCTAssertEqual(Set(traces.map(\.pattern)), Set(FeedNavigationTrace.Pattern.allCases))
        var focusChanges = 0
        for trace in traces {
            let firstCold = try replayer.replay(trace, items: items)
            let secondCold = try replayer.replay(trace, items: items)
            XCTAssertEqual(firstCold.report, secondCold.report)
            XCTAssertEqual(try firstCold.report.artifact(), try secondCold.report.artifact())
            XCTAssertLessThanOrEqual(
                firstCold.report.maximumResidentItems,
                limits.maximumResidentItems
            )
            XCTAssertLessThanOrEqual(
                firstCold.report.maximumEstimatedPreparationBytes,
                limits.maximumEstimatedPreparationBytes
            )
            XCTAssertGreaterThan(firstCold.report.cancellationCount, 0)

            let firstWarm = try replayer.replay(
                trace,
                items: items,
                initiallyCachedItemIDs: firstCold.warmedItemIDs
            )
            let secondWarm = try replayer.replay(
                trace,
                items: items,
                initiallyCachedItemIDs: firstCold.warmedItemIDs
            )
            XCTAssertEqual(firstWarm.report, secondWarm.report)
            XCTAssertEqual(firstWarm.report.cacheMode, FeedTraceReplayReport.CacheMode.warm)
            XCTAssertEqual(firstWarm.report.cacheMisses, 0)
            XCTAssertGreaterThan(firstWarm.report.cacheHits, 0)
            focusChanges += firstCold.report.focusChangeCount
        }
        XCTAssertGreaterThanOrEqual(focusChanges, 500)
    }

    func testTraceFailureContainsActionableNameStepAndIssue() throws {
        let malformed = FeedNavigationTrace(
            name: "broken-paging-trace",
            pattern: .pagedSwipes,
            steps: [.init(
                focusedItemIndex: 99,
                visibleItems: [],
                velocityInViewportsPerSecond: 0,
                predictedDestinations: [],
                elapsedMilliseconds: 0
            )]
        )

        XCTAssertThrowsError(try malformed.signals(for: makeItems(count: 4))) { error in
            let traceError = error as? FeedTraceError
            XCTAssertEqual(traceError?.traceName, "broken-paging-trace")
            XCTAssertEqual(traceError?.stepIndex, 0)
            XCTAssertEqual(traceError?.issue, "focused item index 99 is outside 0..<4")
            XCTAssertEqual(
                traceError?.description,
                "Trace 'broken-paging-trace' failed at step 0: focused item index 99 is outside 0..<4"
            )
            let artifact = try? traceError?.artifact()
            let artifactText = artifact.flatMap { String(data: $0, encoding: .utf8) }
            XCTAssertTrue(artifactText?.contains("broken-paging-trace") == true)
            XCTAssertTrue(artifactText?.contains("focused item index 99") == true)
        }
    }
}

private extension FeedFixtureHarnessTests {
    func mediaPlaylist(named name: String, parser: HLSParser) throws -> MediaPlaylist {
        let playlistURL = try fixtureURL("\(name)/playlist.m3u8")
        let text = try String(contentsOf: playlistURL, encoding: .utf8)
        let manifest = try parser.parse(text, baseURL: playlistURL)
        return try XCTUnwrap(manifest.mediaPlaylist)
    }

    func fixtureData(_ path: String) throws -> Data {
        try Data(contentsOf: fixtureURL(path))
    }

    func fixtureURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        let filename = try XCTUnwrap(components.last)
        let subdirectory = (["Fixtures"] + components.dropLast()).joined(separator: "/")
        let fileURL = Bundle.module.url(
            forResource: (filename as NSString).deletingPathExtension,
            withExtension: (filename as NSString).pathExtension,
            subdirectory: subdirectory
        )
        return try XCTUnwrap(fileURL, "Missing fixture \(path)")
    }

    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
    }

    func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for feed fixture origin state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func makeItems(count: Int) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            let source: FeedPlaybackSource = switch index % 4 {
            case 0:
                .stream(
                    url: fixtureWebURL("short-a/playlist.m3u8"),
                    kind: .videoOnDemand
                )
            case 1:
                .stream(
                    url: fixtureWebURL("live/playlist.m3u8"),
                    kind: .live
                )
            case 2:
                .stream(
                    url: fixtureWebURL("long-form/playlist.m3u8"),
                    kind: .videoOnDemand
                )
            default:
                .clips([
                    fixtureWebURL("short-a/playlist.m3u8"),
                    fixtureWebURL("short-b/playlist.m3u8"),
                ])
            }
            return FeedPlaybackItem(
                id: .init(rawValue: "fixture-item-\(index)"),
                source: source,
                estimatedPreparationBytes: 512 * 1_024
            )
        }
    }

    func fixtureWebURL(_ path: String) -> URL {
        guard let url = URL(string: "https://fixture.invalid/\(path)") else {
            preconditionFailure("Invalid fixture URL path: \(path)")
        }
        return url
    }
}
#endif
