#if canImport(AVFoundation) && canImport(Network)
import XCTest
import AVFoundation
import Network
@testable import ProxyPlayerKit
@testable import HLSCore
@testable import LocalProxy

@MainActor
final class ProxyPlayerKitAVIntegrationTests: XCTestCase {
    func testAVPlayerHitsProxyPlaylistAndSegments() async throws {
        let origin = try MockOriginServer()
        try await origin.start()
        defer { origin.stop() }

        let configuration = ProxyPlayerConfiguration(
            bufferPolicy: .init(targetBufferSeconds: 2, maxPrefetchSegments: 2, hideUntilBuffered: false),
            allowInsecureManifests: true
        )
        let player = ProxyHLSPlayer(configuration: configuration)

        await player.load(from: origin.manifestURL, quality: .automatic)
        player.play()

        guard let playlistURL = player.playlistURL() else {
            XCTFail("Missing playlist URL")
            return
        }

        let (playlistData, _) = try await URLSession.shared.data(from: playlistURL)
        XCTAssertFalse(playlistData.isEmpty)

        guard
            let playlistString = String(data: playlistData, encoding: .utf8),
            let segmentLine = playlistString
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("http://") }),
            let segmentURL = URL(string: String(segmentLine))
        else {
            XCTFail("Unable to locate segment URL in playlist")
            return
        }

        let (segmentData, _) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual(segmentData.count, 1_024)

        player.stop()
    }

}

private final class MockOriginServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockOriginServer")
    private var listener: NWListener?
    private let manifest: String
    private let segments: [String: Data]
    let mediaSequence: Int
    let segmentSize: Int

    init(segmentCount: Int = 1, mediaSequence: Int = 1, segmentDuration: TimeInterval = 4, segmentSize: Int = 1_024) throws {
        self.mediaSequence = mediaSequence
        self.segmentSize = segmentSize

        var manifestLines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(segmentDuration))",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)"
        ]

        var storage: [String: Data] = [:]
        for index in 0..<segmentCount {
            let sequence = mediaSequence + index
            manifestLines.append("#EXTINF:\(segmentDuration),")
            manifestLines.append("/segment-\(sequence).ts")
            storage["/segment-\(sequence).ts"] = Data(repeating: UInt8(sequence % 255), count: segmentSize)
        }

        manifestLines.append("#EXT-X-ENDLIST")
        self.manifest = manifestLines.joined(separator: "\n")
        self.segments = storage
    }

    var manifestURL: URL {
        guard let port = listener?.port?.rawValue else {
            fatalError("Server not started")
        }
        return URL(string: "http://127.0.0.1:\(port)/master.m3u8")!
    }

    func start() async throws {
        listener = try NWListener(using: .tcp, on: 0)
        try await withCheckedThrowingContinuation { continuation in
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener?.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }

            let response = self.response(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for data: Data) -> Data {
        guard
            let request = String(data: data, encoding: .utf8)?
                .components(separatedBy: .newlines)
                .first,
            let path = request.split(separator: " ").dropFirst().first
        else {
            return HTTPResponse(status: .notFound).encoded()
        }

        if path == "/master.m3u8" {
            return HTTPResponse.text(manifest, contentType: "application/x-mpegURL").encoded()
        }

        if let data = segments[String(path)] {
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "video/mp2t"],
                body: data
            ).encoded()
        }

        return HTTPResponse(status: .notFound).encoded()
    }
}

#endif
