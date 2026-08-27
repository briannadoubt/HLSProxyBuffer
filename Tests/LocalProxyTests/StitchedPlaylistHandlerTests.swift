#if canImport(Network)
import Foundation
import XCTest
@testable import HLSCore
@testable import LocalProxy

@available(macOS 12.0, *)
final class StitchedPlaylistHandlerTests: XCTestCase {
    func testExistingWildcardRouteServesEveryStitchedMapAndSegment() async throws {
        let firstMap = URL(string: "https://one.origin.example/init.mp4")!
        let secondMap = URL(string: "https://two.origin.example/init.mp4")!
        let firstSegment = URL(string: "https://one.origin.example/first.m4s?token=one")!
        let secondSegment = URL(string: "https://one.origin.example/second.m4s?token=two")!
        let thirdSegment = URL(string: "https://two.origin.example/third.m4s?token=three")!
        let signature = HLSClipMediaSignature(
            container: .fragmentedMP4,
            codecs: ["mp4a.40.2"],
            tracks: [.init(kind: .audio, codec: "mp4a.40.2", layout: "stereo")],
            segmentsAreIndependent: false
        )
        let stitched = try HLSClipStitcher().stitch([
            HLSClip(
                id: "first",
                playlist: MediaPlaylist(
                    targetDuration: 2,
                    mediaSequence: 10,
                    segments: [
                        HLSSegment(
                            url: firstSegment,
                            duration: 2,
                            sequence: 10,
                            initializationMap: .init(uri: firstMap)
                        ),
                        HLSSegment(
                            url: secondSegment,
                            duration: 2,
                            sequence: 11,
                            initializationMap: .init(uri: firstMap)
                        ),
                    ],
                    isEndlist: true,
                    playlistType: "VOD"
                ),
                mediaSignature: signature
            ),
            HLSClip(
                id: "second",
                playlist: MediaPlaylist(
                    targetDuration: 2,
                    mediaSequence: 20,
                    segments: [HLSSegment(
                        url: thirdSegment,
                        duration: 2,
                        sequence: 20,
                        initializationMap: .init(uri: secondMap)
                    )],
                    isEndlist: true,
                    playlistType: "VOD"
                ),
                mediaSignature: signature
            ),
        ])
        let bytes: [URL: Data] = [
            firstMap: Data("first-map".utf8),
            secondMap: Data("second-map".utf8),
            firstSegment: Data("first-segment".utf8),
            secondSegment: Data("second-segment".utf8),
            thirdSegment: Data("third-segment".utf8),
        ]
        let source = StitchedResourceSource(bytes: bytes)
        let cache = HLSSegmentCache()
        let catalog = SegmentCatalog()
        await catalog.update(with: stitched)
        let scheduler = SegmentPrefetchScheduler()
        let store = PlaylistStore()
        let router = ProxyRouter()
        router.register(path: "/playlist.m3u8", handler: PlaylistHandler(store: store).makeHandler())
        router.register(
            path: "/segments/*",
            handler: SegmentHandler(
                cache: cache,
                catalog: catalog,
                fetcher: source,
                scheduler: scheduler
            ).makeHandler()
        )
        let server = ProxyServer(router: router)
        try server.start()
        defer { server.stop() }
        let baseURL = try await waitForStitchedBaseURL(server)
        let config = HLSRewriteConfiguration(proxyBaseURL: baseURL)
        let text = HLSRewriter().rewrite(
            mediaPlaylist: stitched,
            config: config,
            bufferState: BufferState(readySequences: Set(stitched.segments.map(\.sequence)))
        )
        await store.update(text)

        XCTAssertFalse(text.contains("origin.example"))
        XCTAssertFalse(text.contains("token="))
        XCTAssertEqual(text.split(separator: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count, 1)
        let playlistURL = baseURL.appendingPathComponent("playlist.m3u8")
        let loaded = String(decoding: try await URLSession.shared.data(from: playlistURL).0, as: UTF8.self)
        XCTAssertEqual(loaded, text)

        let lines = text.split(separator: "\n").map(String.init)
        let segmentURLs = try lines
            .filter { !$0.hasPrefix("#") && $0.hasPrefix("http://") }
            .map { try XCTUnwrap(URL(string: $0)) }
        let mapURLs = try lines
            .filter { $0.hasPrefix("#EXT-X-MAP:") }
            .map { try XCTUnwrap(stitchedQuotedURI(in: $0)) }
        XCTAssertEqual(segmentURLs.count, 3)
        XCTAssertEqual(mapURLs.count, 2)
        XCTAssertTrue(segmentURLs.allSatisfy { $0.pathExtension == "m4s" })
        XCTAssertTrue(mapURLs.allSatisfy { $0.pathExtension == "mp4" })

        var delivered = Set<Data>()
        for url in mapURLs + segmentURLs {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                "video/mp4"
            )
            delivered.insert(data)
        }
        XCTAssertEqual(delivered, Set(bytes.values))
        let fetchCount = await source.fetchCount()
        XCTAssertEqual(fetchCount, 5)
    }
}

private actor StitchedResourceSource: SegmentSource {
    private let bytes: [URL: Data]
    private var count = 0

    init(bytes: [URL: Data]) {
        self.bytes = bytes
    }

    func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        try value(for: segment.url)
    }

    func fetchResource(at url: URL, byteRange: ClosedRange<Int>?) async throws -> Data {
        let data = try value(for: url)
        guard let byteRange else { return data }
        return data.subdata(in: byteRange.lowerBound..<(byteRange.upperBound + 1))
    }

    func fetchCount() -> Int { count }

    private func value(for url: URL) throws -> Data {
        count += 1
        guard let data = bytes[url] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

@available(macOS 12.0, *)
private func waitForStitchedBaseURL(_ server: ProxyServer) async throws -> URL {
    for _ in 0..<50 {
        if let baseURL = server.baseURL, server.port != 0 { return baseURL }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw URLError(.cannotConnectToHost)
}

private func stitchedQuotedURI(in tag: String) -> URL? {
    guard let start = tag.range(of: "URI=\"")?.upperBound,
          let end = tag[start...].firstIndex(of: "\"")
    else { return nil }
    return URL(string: String(tag[start..<end]))
}
#endif
