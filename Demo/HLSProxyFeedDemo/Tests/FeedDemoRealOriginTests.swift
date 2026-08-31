import Foundation
import AVFoundation
import HLSCore
import LocalProxy
@testable import ProxyPlayerKit
import XCTest
@testable import HLSProxyFeedDemo

final class FeedDemoRealOriginTests: XCTestCase {
    func testInjectedNetworkSessionSurvivesLibraryOwnerLifetimes() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let resource = try segment(in: library)
        let url = baseURL.appendingPathComponent(library.catalog.corpusVersion + "/" + resource.path)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        var fetcher: HLSSegmentFetcher? = HLSSegmentFetcher(session: session)
        weak var releasedFetcher = fetcher
        fetcher = nil
        XCTAssertNil(releasedFetcher)
        let afterFetcher = try await session.data(from: url).0
        XCTAssertFalse(afterFetcher.isEmpty)

        var refresher: PlaylistRefreshController? = PlaylistRefreshController(session: session)
        weak var releasedRefresher = refresher
        refresher = nil
        XCTAssertNil(releasedRefresher)
        let afterRefresher = try await session.data(from: url).0
        XCTAssertFalse(afterRefresher.isEmpty)

        var backend: HLSFeedPreparationBackend? = try HLSFeedPreparationBackend(
            policy: .shortFormFeed, allowsInsecureManifests: true, session: session
        )
        weak var releasedBackend = backend
        backend = nil
        XCTAssertNil(releasedBackend)
        let afterBackend = try await session.data(from: url).0
        XCTAssertFalse(afterBackend.isEmpty)
    }

    @MainActor
    func testAdaptivePlaybackPreservesPublishedVODPlaylistsAndRoutes() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil,
           ProcessInfo.processInfo.environment["RUN_PROXY_AV_TESTS"] == nil {
            throw XCTSkip("Native AVPlayer opt-in on hosted CI")
        }
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let entries = try FeedDemoCatalog.entries(for: .shortForm, baseURL: baseURL, library: origin.library)
        guard case .stream(let remoteURL, _) = entries[2].item.source else { return XCTFail("Missing stream") }
        var configuration = try FeedPlaybackPolicy.shortFormFeed.makeProxyPlayerConfiguration()
        configuration.allowInsecureManifests = true
        configuration.cachePolicy.enableDiskCache = false
        let proxy = ProxyHLSPlayer(configuration: configuration)
        await proxy.load(from: remoteURL)
        let prepared = await proxy.prepareForImmediatePlayback(retryPolicy: .automaticFeed)
        XCTAssertTrue(prepared)
        let masterURL = try XCTUnwrap(proxy.playlistURL())
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let master = try HLSParser().parse(String(decoding: try await session.data(from: masterURL).0, as: UTF8.self), baseURL: masterURL)
        let variantURL = try XCTUnwrap(master.variants.first?.url)
        let original = try await session.data(from: variantURL).0
        let playlist = try XCTUnwrap(HLSParser().parse(String(decoding: original, as: UTF8.self), baseURL: variantURL).mediaPlaylist)
        proxy.play()
        let switchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while proxy.telemetrySnapshot.variantSwitchReasonCounts.isEmpty, ContinuousClock.now < switchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(proxy.telemetrySnapshot.variantSwitchReasonCounts.isEmpty, "Exercise an actual adaptive decision")
        let revisited = try await session.data(from: variantURL).0
        XCTAssertEqual(original, revisited, "A published VOD URL must stay byte-identical across adaptive decisions")
        for segment in playlist.segments {
            let (_, response) = try await session.data(from: segment.url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Published segment routes must remain available")
        }
        await proxy.stopAndWait()
    }

    @MainActor
    func testRealClipsContinueAfterLoopRewind() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil,
           ProcessInfo.processInfo.environment["RUN_PROXY_AV_TESTS"] == nil { throw XCTSkip("Native AVPlayer opt-in on hosted CI") }
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let entries = try FeedDemoCatalog.entries(for: .shortForm, baseURL: baseURL, library: origin.library)
        var policy = FeedPlaybackPolicy.shortFormFeed
        policy.eviction.usesDiskCache = false
        for entry in entries.prefix(3) {
            let engine = try HLSFeedEngine(items: [entry.item], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP)
            try await engine.update(.init(
                generation: .init(rawValue: 1), focusedItemID: entry.id,
                visibleItems: [.init(itemID: entry.id, fraction: 1, distanceInViewports: 0)],
                observedAt: .zero
            ))
            _ = await engine.waitUntilSettled()
            let player = try XCTUnwrap(engine.platformPlayer(for: entry.id))
            let startDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while player.timeControlStatus != .playing, ContinuousClock.now < startDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(player.timeControlStatus, .playing)
            let didSeek = await player.seek(
                to: CMTime(seconds: 7.9, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero
            )
            XCTAssertTrue(didSeek)
            XCTAssertGreaterThan(player.currentTime().seconds, 7.5, "Seek must reach the final segment before measuring a loop")
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                let time = player.currentTime().seconds
                if time > 0.2 && time < 7 && player.timeControlStatus == .playing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(player.currentTime().seconds, 0.2)
            XCTAssertLessThan(player.currentTime().seconds, 7)
            XCTAssertEqual(player.timeControlStatus, .playing)
            await engine.stop()
        }
    }

    @MainActor
    func testAllRealModesReachPlatformPlayback() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil,
           ProcessInfo.processInfo.environment["RUN_PROXY_AV_TESTS"] == nil {
            throw XCTSkip("Hosted AVPlayer playback is covered by the real iOS UI gate; opt in with RUN_PROXY_AV_TESTS=1.")
        }
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        for mode in FeedDemoMode.allCases {
            let entries = try FeedDemoCatalog.entries(for: mode, baseURL: baseURL, library: library)
            let engine = try HLSFeedEngine(
                items: entries.map(\.item), policy: mode.policy,
                sourceTransportPolicy: .allowLoopbackHTTP
            )
            let item = try XCTUnwrap(entries.first)
            try await engine.update(FeedViewportSignal(
                generation: .init(rawValue: 1), focusedItemID: item.id,
                visibleItems: [.init(itemID: item.id, fraction: 1, distanceInViewports: 0)],
                observedAt: .zero
            ))
            _ = await engine.waitUntilSettled()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while engine.snapshot.playback(for: item.id)?.hasStartedPlayback != true,
                  engine.snapshot.failures.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let originFailures = await origin.snapshot().records.filter { $0.statusCode >= 400 }.suffix(8)
            XCTAssertTrue(engine.snapshot.failures.isEmpty, "\(mode): \(engine.snapshot.failures); origin: \(originFailures)")
            XCTAssertEqual(engine.snapshot.audibleItemID, item.id, "\(mode)")
            XCTAssertEqual(engine.snapshot.playback(for: item.id)?.hasStartedPlayback, true, "\(mode)")
            await engine.stop()
        }
    }

    func testRealCatalogUsesVersionedMastersAndMeasuredStitchingTracks() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let entries = try FeedDemoCatalog.entries(for: .shortForm, baseURL: baseURL, library: library)
        XCTAssertEqual(entries.count, 24)
        XCTAssertEqual(entries.first?.id, "short-0")
        XCTAssertTrue(entries.allSatisfy { $0.attribution?.isEmpty == false })
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for entry in entries {
            guard case .stream(let url, .videoOnDemand) = entry.item.source else {
                return XCTFail("Expected a VOD master")
            }
            XCTAssertTrue(url.path.hasPrefix("/\(library.catalog.corpusVersion)/feed-"))
            let (data, _) = try await session.data(from: url)
            let manifest = try HLSParser().parse(String(decoding: data, as: UTF8.self), baseURL: url)
            XCTAssertEqual(manifest.kind, .master)
            XCTAssertEqual(manifest.variants.count, 2)
        }
        let stitched = try FeedDemoCatalog.entries(for: .stitched, baseURL: baseURL, library: library)
        guard case .compatibleClips(let clips) = try XCTUnwrap(stitched.first).item.source else {
            return XCTFail("Expected compatible real clips")
        }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].mediaSignature, clips[1].mediaSignature)
        XCTAssertEqual(clips[0].mediaSignature.codecs, ["avc1.64001f", "mp4a.40.2"])
        XCTAssertTrue(clips.allSatisfy { $0.playlistURL.path.contains("/360p/") })
        for mode in FeedDemoMode.allCases {
            XCTAssertFalse(try FeedDemoCatalog.entries(for: mode, baseURL: baseURL, library: library).isEmpty)
        }
    }

    func testHeadAndConditionalValidationReadNoMediaBodies() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let resource = try segment(in: library)
        let url = baseURL.appendingPathComponent(library.catalog.corpusVersion + "/" + resource.path)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for headers in [[:], ["Range": "bytes=0-31"], ["If-None-Match": resource.etag]] {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertTrue(data.isEmpty)
            if headers["If-None-Match"] == nil {
                XCTAssertEqual(http.statusCode, 200)
                XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), String(resource.byteCount))
            } else { XCTAssertEqual(http.statusCode, 304) }
        }
        var request = URLRequest(url: url)
        request.setValue(resource.etag, forHTTPHeaderField: "If-None-Match")
        let (_, validated) = try await session.data(for: request)
        XCTAssertEqual((validated as? HTTPURLResponse)?.statusCode, 304)
        let snapshot = await origin.snapshot()
        XCTAssertEqual(snapshot.bodyBudget.materializationCount, 0)
        XCTAssertEqual(snapshot.responseByteCount, 0)
    }

    func testRangesAndValidatorPrecedenceMatchCanonicalBytes() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let resource = try segment(in: library)
        let expected = try Data(contentsOf: library.resourceURL(for: resource.path))
        let url = baseURL.appendingPathComponent(library.catalog.corpusVersion + "/" + resource.path)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for (range, bytes) in [("bytes=0-31", expected.prefix(32)), ("bytes=-32", expected.suffix(32)), ("bytes=32-", expected.dropFirst(32))] {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(data, Data(bytes))
        }
        var request = URLRequest(url: url)
        request.setValue("\"not-current\"", forHTTPHeaderField: "If-None-Match")
        request.setValue("Wed, 26 Aug 2026 00:00:00 GMT", forHTTPHeaderField: "If-Modified-Since")
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        request.setValue("\"not-current\"", forHTTPHeaderField: "If-Range")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, expected)
    }

    func testBodyAdmissionIsBoundedAndStopDrainsDelayedRequests() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        let library = try XCTUnwrap(origin.library)
        let resource = try segment(in: library)
        let url = baseURL.appendingPathComponent(library.catalog.corpusVersion + "/" + resource.path)
        let session = makeSession()
        defer { origin.stop(); session.invalidateAndCancel() }
        await origin.setNetworkProfile(.init(bytesPerSecond: 1))
        let tasks = (0..<8).map { _ in Task { try await session.data(from: url) } }
        defer { for task in tasks { task.cancel() } }
        try await waitUntil {
            let state = await origin.snapshot()
            return state.bodyBudget.activeBodyCount == 4 && state.bodyBudget.queuedCount > 0
        }
        let loaded = await origin.snapshot()
        XCTAssertEqual(loaded.bodyBudget.maximumBodyCount, 4)
        XCTAssertEqual(loaded.bodyBudget.maximumBodyBytes, resource.byteCount * 4)
        XCTAssertLessThanOrEqual(loaded.bodyBudget.maximumBodyBytes, 4 * 1_024 * 1_024)
        let started = ContinuousClock.now
        origin.stop()
        try await waitUntil {
            let state = await origin.snapshot()
            return state.bodyBudget.activeBodyCount == 0 && state.bodyBudget.queuedCount == 0 && state.activeRequestCount == 0
        }
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(250))
        for task in tasks { _ = try? await task.value }
    }

    func testPreferredOriginFallsBackHonestlyWithoutChangingCanonicalPath() async throws {
        let reservation = ProxyServer(router: ProxyRouter())
        let reservedURL = try await reservation.startAndWait()
        defer { reservation.stop() }
        let reservedPort = try XCTUnwrap(UInt16(exactly: try XCTUnwrap(reservedURL.port)))
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real, preferredPort: reservedPort))
        let actual = try await origin.start()
        defer { origin.stop() }
        XCTAssertNotEqual(actual.port, reservedURL.port)
        let library = try XCTUnwrap(origin.library)
        let entries = try FeedDemoCatalog.entries(for: .shortForm, baseURL: actual, library: library)
        guard case .stream(let url, _) = entries[0].item.source else { return XCTFail("Expected stream") }
        XCTAssertEqual(url.port, actual.port)
        XCTAssertTrue(url.path.contains(library.catalog.corpusVersion))
    }

    func testClientCancellationReleasesThrottledBody() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let resource = try segment(in: library)
        await origin.setNetworkProfile(.init(bytesPerSecond: 1))
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let url = baseURL.appendingPathComponent(library.catalog.corpusVersion + "/" + resource.path)
        let task = Task { try await session.data(from: url) }
        try await waitUntil { await origin.snapshot().bodyBudget.activeBodyCount == 1 }
        let cancelledAt = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        try await waitUntil { await origin.snapshot().bodyBudget.activeBodyCount == 0 }
        XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(250))
        let state = await origin.snapshot()
        XCTAssertEqual(state.cancelledRequestCount, 1)
        XCTAssertEqual(state.responseByteCount, 0)
    }

    func testUnknownRequestsDoNotGrowAccountingKeys() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for index in 0..<20 {
            let (_, response) = try await session.data(from: baseURL.appendingPathComponent("unknown-\(index)"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }
        let state = await origin.snapshot()
        XCTAssertEqual(state.requestsByPath.count, 1)
        XCTAssertEqual(state.bodyBudget.materializationCount, 0)
    }

    func testRecordedLiveWindowPreservesDiscontinuityAtWrap() throws {
        let library = try FeedDemoMediaLibrary.bundled()
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:49374"))
        let before = try XCTUnwrap(FeedDemoLivePlaylist.make(library: library, elapsedSeconds: 30))
        let after = try XCTUnwrap(FeedDemoLivePlaylist.make(library: library, elapsedSeconds: 32))
        let first = try XCTUnwrap(HLSParser().parse(before.text, baseURL: base).mediaPlaylist)
        let second = try XCTUnwrap(HLSParser().parse(after.text, baseURL: base).mediaPlaylist)
        XCTAssertEqual(first.mediaSequence, 15)
        XCTAssertEqual(first.discontinuitySequence, 0)
        XCTAssertEqual(second.mediaSequence, 16)
        XCTAssertEqual(second.discontinuitySequence, 1)
        XCTAssertEqual(first.segments.count, 6)
        XCTAssertEqual(first.segments[1].url, second.segments[0].url)
        XCTAssertTrue(first.segments[1].metadataTags.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertFalse(second.segments[0].metadataTags.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertFalse(first.isEndlist)
        XCTAssertNil(first.playlistType)
    }

    func testRestartReusesStableCanonicalOriginIdentity() async throws {
        let first = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let initial = try await first.start()
        let port = try XCTUnwrap(UInt16(exactly: try XCTUnwrap(initial.port)))
        let library = try XCTUnwrap(first.library)
        let resource = try segment(in: library)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let path = library.catalog.corpusVersion + "/" + resource.path
        let original = try await session.data(from: initial.appendingPathComponent(path)).0
        first.stop()
        let restarted = try FeedDemoFixtureOrigin(configuration: .init(media: .real, preferredPort: port))
        let next = try await restarted.start()
        defer { restarted.stop() }
        XCTAssertEqual(initial, next, "Stable binding must preserve the actual canonical cache key")
        let reloaded = try await session.data(from: next.appendingPathComponent(path)).0
        XCTAssertEqual(original, reloaded)
    }

    func testAccountingResetDoesNotMixOldCompletionsIntoNewWindow() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let resource = try segment(in: library)
        await origin.setNetworkProfile(.init(responseDelay: .milliseconds(100)))
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let url = baseURL.appendingPathComponent(library.catalog.corpusVersion + "/" + resource.path)
        let task = Task { try await session.data(from: url) }
        try await waitUntil { await origin.snapshot().activeRequestCount == 1 }
        await origin.resetRequestAccounting()
        _ = try await task.value
        let state = await origin.snapshot()
        XCTAssertEqual(state.activeRequestCount, 0)
        XCTAssertEqual(state.requestCount, 0)
        XCTAssertEqual(state.responseByteCount, 0)
        XCTAssertTrue(state.records.isEmpty)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    private func segment(in library: FeedDemoMediaLibrary) throws -> FeedDemoMediaLibrary.Resource {
        let clip = try XCTUnwrap(library.shortClips.first)
        let path = try XCTUnwrap(clip.renditions.first { $0.id == "720p" }?.segmentPaths.first)
        return try XCTUnwrap(library.resourcesByPath[path])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
