#if canImport(Network)
import XCTest
@testable import LocalProxy
@testable import HLSCore

@available(macOS 12.0, *)
final class ProxyServerIntegrationTests: XCTestCase {
    func testOnDemandFetchServesSegmentAndRefreshesPlaylist() async throws {
        let playlist = MediaPlaylist(
            targetDuration: 4,
            mediaSequence: 1,
            segments: [
                HLSSegment(url: URL(string: "https://cdn.example.com/seg1.ts")!, duration: 4, sequence: 1),
                HLSSegment(url: URL(string: "https://cdn.example.com/seg2.ts")!, duration: 4, sequence: 2),
            ]
        )

        let cache = HLSSegmentCache()
        let catalog = SegmentCatalog()
        await catalog.update(with: playlist)
        let scheduler = SegmentPrefetchScheduler()
        let fetcher = MockSegmentFetcher(dataBySequence: [
            1: Data("segment-one".utf8),
            2: Data("segment-two".utf8),
        ])

        let router = ProxyRouter()
        let playlistStore = PlaylistStore()
        router.register(path: "/playlist.m3u8", handler: PlaylistHandler(store: playlistStore).makeHandler())
        let segmentHandler = SegmentHandler(
            cache: cache,
            catalog: catalog,
            fetcher: fetcher,
            scheduler: scheduler
        )
        router.register(path: "/segments/*", handler: segmentHandler.makeHandler())

        let server = ProxyServer(router: router)
        try server.start()
        let baseURL = try await waitForBaseURL(server: server)

        defer {
            server.stop()
            Task {
                await scheduler.onBufferStateChange(nil)
                await scheduler.stop()
            }
        }

        let config = HLSRewriteConfiguration(
            proxyBaseURL: baseURL,
            hideUntilBuffered: true,
            lowLatencyOptions: .init(canSkipUntil: 6, allowBlockingReload: true, prefetchHintCount: 1, enableDeltaUpdates: true)
        )

        let rewriter = HLSRewriter()
        await scheduler.onBufferStateChange { state in
            let playlistText = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: state)
            await playlistStore.update(playlistText)
        }

        let initialText = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: BufferState())
        await playlistStore.update(initialText)

        let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
        let (playlistData, _) = try await URLSession.shared.data(from: playlistURL)
        let initialPlaylistString = String(decoding: playlistData, as: UTF8.self)
        XCTAssertFalse(initialPlaylistString.contains("#EXTINF"), "Segments should be hidden until buffered")

        let segmentURL = config.segmentURL(for: playlist.segments[0])
        let (segmentData, _) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual(segmentData, Data("segment-one".utf8))
        let firstCount = await fetcher.currentCount()
        XCTAssertEqual(firstCount, 1, "Fetcher should be hit once for first segment")

        let updatedPlaylistString = try await waitForPlaylist(at: playlistURL) {
            $0.contains("segment-1")
        }
        XCTAssertTrue(
            updatedPlaylistString.contains("segment-1"),
            "Playlist should reveal buffered segment; got \(updatedPlaylistString)"
        )

        let (_, _) = try await URLSession.shared.data(from: segmentURL)
        let finalCount = await fetcher.currentCount()
        XCTAssertEqual(finalCount, 1, "Subsequent requests should be served from cache")

        var rangeRequest = URLRequest(url: segmentURL)
        rangeRequest.setValue("bytes=0-6", forHTTPHeaderField: "Range")
        let (rangeData, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
        XCTAssertEqual((rangeResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(rangeData, Data("segment".utf8))
        XCTAssertEqual((rangeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-6/11")

        var headRequest = URLRequest(url: segmentURL)
        headRequest.httpMethod = "HEAD"
        headRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (headData, headResponse) = try await URLSession.shared.data(for: headRequest)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "11")

        let queryURL = URL(string: playlistURL.absoluteString + "?_HLS_msn=1")!
        let (queryData, queryResponse) = try await URLSession.shared.data(from: queryURL)
        XCTAssertEqual((queryResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: queryData, as: UTF8.self).contains("#EXTM3U"))
    }

    func testConcurrentMissesCoalesceIntoSingleOriginFetch() async throws {
        let segment = HLSSegment(
            url: URL(string: "https://cdn.example.com/shared.m4s")!,
            duration: 2,
            sequence: 10
        )
        let playlist = MediaPlaylist(targetDuration: 2, segments: [segment])
        let cache = HLSSegmentCache(capacityBytes: 1_024)
        let catalog = SegmentCatalog()
        await catalog.update(with: playlist)
        let scheduler = SegmentPrefetchScheduler()
        let fetcher = MockSegmentFetcher(dataBySequence: [10: Data("shared-data".utf8)], delay: 0.1)
        let router = ProxyRouter()
        router.register(
            path: "/segments/*",
            handler: SegmentHandler(cache: cache, catalog: catalog, fetcher: fetcher, scheduler: scheduler).makeHandler()
        )
        let server = ProxyServer(router: router)
        try server.start()
        defer { server.stop() }
        let baseURL = try await waitForBaseURL(server: server)
        let url = HLSRewriteConfiguration(proxyBaseURL: baseURL).segmentURL(for: segment)

        let responses = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0..<8 {
                group.addTask { try await URLSession.shared.data(from: url).0 }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(Set(responses), [Data("shared-data".utf8)])
        let count = await fetcher.currentCount()
        XCTAssertEqual(count, 1)
    }
}

private actor MockSegmentFetcher: SegmentSource {
    private let dataBySequence: [Int: Data]
    private let delay: TimeInterval
    private(set) var fetchCount: Int = 0

    init(dataBySequence: [Int: Data], delay: TimeInterval = 0) {
        self.dataBySequence = dataBySequence
        self.delay = delay
    }

    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        fetchCount += 1
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard let data = dataBySequence[segment.sequence] else {
            throw URLError(.fileDoesNotExist)
        }
        return data
    }

    func currentCount() -> Int {
        fetchCount
    }
}

@available(macOS 12.0, *)
private func waitForBaseURL(server: ProxyServer) async throws -> URL {
    for _ in 0..<50 {
        if let port = server.port, port != 0, let url = server.baseURL {
            return url
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw URLError(.cannotConnectToHost)
}

@available(macOS 12.0, *)
private func waitForPlaylist(
    at url: URL,
    timeout: TimeInterval = 2,
    predicate: (String) -> Bool
) async throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    var latest = ""
    repeat {
        latest = String(decoding: try await URLSession.shared.data(from: url).0, as: UTF8.self)
        if predicate(latest) { return latest }
        try await Task.sleep(nanoseconds: 20_000_000)
    } while Date() < deadline
    return latest
}
#endif
