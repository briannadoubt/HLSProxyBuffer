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

        let segmentURL = baseURL.appendingPathComponent("segments/segment-1")
        let (segmentData, _) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual(segmentData, Data("segment-one".utf8))
        let firstCount = await fetcher.currentCount()
        XCTAssertEqual(firstCount, 1, "Fetcher should be hit once for first segment")

        try await Task.sleep(nanoseconds: 200_000_000)

        let (updatedPlaylistData, _) = try await URLSession.shared.data(from: playlistURL)
        let updatedPlaylistString = String(decoding: updatedPlaylistData, as: UTF8.self)
        XCTAssertTrue(updatedPlaylistString.contains("segment-1"), "Playlist should reveal buffered segment")

        let (_, _) = try await URLSession.shared.data(from: segmentURL)
        let finalCount = await fetcher.currentCount()
        XCTAssertEqual(finalCount, 1, "Subsequent requests should be served from cache")
    }
}

private actor MockSegmentFetcher: SegmentSource {
    private let dataBySequence: [Int: Data]
    private(set) var fetchCount: Int = 0

    init(dataBySequence: [Int: Data]) {
        self.dataBySequence = dataBySequence
    }

    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        fetchCount += 1
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
#endif
