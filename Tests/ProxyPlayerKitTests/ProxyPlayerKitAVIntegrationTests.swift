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

        let (masterData, _) = try await URLSession.shared.data(from: playlistURL)
        XCTAssertFalse(masterData.isEmpty)

        guard
            let masterString = String(data: masterData, encoding: .utf8),
            let variantLine = masterString
                .split(separator: "\n")
                .last(where: { !$0.hasPrefix("#") }),
            let variantURL = URL(string: String(variantLine))
        else {
            XCTFail("Unable to locate variant URL")
            return
        }

        let (variantData, _) = try await URLSession.shared.data(from: variantURL)
        XCTAssertFalse(variantData.isEmpty)

        guard
            let playlistString = String(data: variantData, encoding: .utf8),
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

    func testSwitchesVariantsAfterFailures() async throws {
        let origin = AdaptiveMockOriginServer()
        try await origin.start()
        defer { origin.stop() }

        let switchedExpectation = expectation(description: "Switched to low variant")
        let diagnostics = ProxyPlayerDiagnostics(onQualityChanged: { variant in
            if variant.url.absoluteString.contains("low") {
                switchedExpectation.fulfill()
            }
        })

        let configuration = ProxyPlayerConfiguration(
            bufferPolicy: .init(targetBufferSeconds: 2, maxPrefetchSegments: 2, hideUntilBuffered: false),
            abrPolicy: .init(failureDowngradeThreshold: 1),
            allowInsecureManifests: true
        )
        let player = ProxyHLSPlayer(configuration: configuration, diagnostics: diagnostics)

        await player.load(from: origin.manifestURL, quality: .automatic)
        await fulfillment(of: [switchedExpectation], timeout: 10)

        guard let playlistURL = player.playlistURL() else {
            XCTFail("Missing playlist URL")
            return
        }

        let (masterData, _) = try await URLSession.shared.data(from: playlistURL)
        XCTAssertFalse(masterData.isEmpty)

        guard
            let masterString = String(data: masterData, encoding: .utf8),
            let variantLine = masterString
                .split(separator: "\n")
                .last(where: { !$0.hasPrefix("#") }),
            let variantURL = URL(string: String(variantLine))
        else {
            XCTFail("Unable to locate variant URL in playlist")
            return
        }

        let (variantData, _) = try await URLSession.shared.data(from: variantURL)
        XCTAssertFalse(variantData.isEmpty)

        guard
            let playlistString = String(data: variantData, encoding: .utf8),
            let segmentLine = playlistString
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("http://") }),
            let segmentURL = URL(string: String(segmentLine))
        else {
            XCTFail("Unable to locate segment URL in playlist")
            return
        }

        let (segmentData, _) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertFalse(segmentData.isEmpty)
        XCTAssertTrue(origin.didServeLowVariant())

        player.stop()
    }

    func testExposesAlternateRenditionsAndSelection() async throws {
        let origin = AdaptiveMockOriginServer(includeAlternateRenditions: true)
        try await origin.start()
        defer { origin.stop() }

        let renditionExpectation = expectation(description: "Rendition callback")
        let diagnostics = ProxyPlayerDiagnostics(onRenditionChanged: { kind, rendition in
            if kind == .audio, rendition?.name == "English" {
                renditionExpectation.fulfill()
            }
        })

        let configuration = ProxyPlayerConfiguration(
            bufferPolicy: .init(targetBufferSeconds: 2, maxPrefetchSegments: 2, hideUntilBuffered: false),
            allowInsecureManifests: true
        )
        let player = ProxyHLSPlayer(configuration: configuration, diagnostics: diagnostics)

        await player.load(from: origin.manifestURL, quality: .automatic)

        try await waitForRenditions(player)
        XCTAssertEqual(player.audioRenditions.count, 1)
        XCTAssertEqual(player.subtitleRenditions.count, 1)
        guard let audio = player.audioRenditions.first else {
            XCTFail("Missing audio rendition")
            return
        }

        player.selectRendition(kind: .audio, id: audio.id)
        await fulfillment(of: [renditionExpectation], timeout: 5)

        guard let audioURI = audio.uri else {
            XCTFail("Missing audio URL")
            return
        }

        let (renditionData, _) = try await URLSession.shared.data(from: audioURI)
        let renditionPlaylist = String(decoding: renditionData, as: UTF8.self)
        XCTAssertTrue(renditionPlaylist.contains("segments/"), "Rendition playlist should be rewritten to proxy segments.")

        guard
            let debugURL = player.playlistURL()?.deletingLastPathComponent().appendingPathComponent("debug/status"),
            let (debugData, _) = try? await URLSession.shared.data(from: debugURL),
            let payload = try JSONSerialization.jsonObject(with: debugData) as? [String: Any]
        else {
            XCTFail("Unable to fetch debug payload")
            return
        }

        XCTAssertEqual(payload["active_audio_rendition"] as? String, "English")

        player.stop()
    }

    func testRewritesKeysInProxyMode() async throws {
        let keyURL = URL(string: "skd://asset/12345")!
        let origin = try MockOriginServer(keyURI: keyURL)
        try await origin.start()
        defer { origin.stop() }

        let keyIdentifier = ProxyHLSPlayer.keyIdentifier(forKeyURI: keyURL)
        let keyData = Data("mock-ckc".utf8)
        let keyExpectation = expectation(description: "Key diagnostics observed")
        let diagnostics = ProxyPlayerDiagnostics(onKeyMetadataChanged: { statuses in
            if statuses.contains(where: { $0.uriHash == keyIdentifier }) {
                keyExpectation.fulfill()
            }
        })

        let configuration = ProxyPlayerConfiguration(
            bufferPolicy: .init(targetBufferSeconds: 2, maxPrefetchSegments: 2, hideUntilBuffered: false),
            allowInsecureManifests: true,
            drmPolicy: .proxy
        )
        let player = ProxyHLSPlayer(configuration: configuration, diagnostics: diagnostics)

        await player.registerAuxiliaryAsset(
            data: keyData,
            identifier: keyIdentifier,
            type: .keys
        )

        await player.load(from: origin.manifestURL, quality: .automatic)
        await fulfillment(of: [keyExpectation], timeout: 5)

        guard let playlistURL = player.playlistURL() else {
            XCTFail("Missing playlist URL")
            return
        }

        let (masterData, _) = try await URLSession.shared.data(from: playlistURL)
        guard
            let masterString = String(data: masterData, encoding: .utf8),
            let variantLine = masterString
                .split(separator: "\n")
                .last(where: { !$0.hasPrefix("#") }),
            let variantURL = URL(string: String(variantLine))
        else {
            XCTFail("Unable to parse variant URL")
            return
        }

        let (variantData, _) = try await URLSession.shared.data(from: variantURL)
        guard let playlistString = String(data: variantData, encoding: .utf8) else {
            XCTFail("Missing variant body")
            return
        }

        XCTAssertTrue(playlistString.contains("/assets/keys/\(keyIdentifier)"))
        XCTAssertFalse(playlistString.contains(keyURL.absoluteString))

        let localKeyURL = playlistURL
            .deletingLastPathComponent()
            .appendingPathComponent("assets/keys/\(keyIdentifier)")
        let (fetchedKeyData, _) = try await URLSession.shared.data(from: localKeyURL)
        XCTAssertEqual(fetchedKeyData, keyData)

        let debugURL = playlistURL
            .deletingLastPathComponent()
            .appendingPathComponent("debug/status")
        guard
            let (debugData, _) = try? await URLSession.shared.data(from: debugURL),
            let payload = try JSONSerialization.jsonObject(with: debugData) as? [String: Any],
            let keys = payload["keys"] as? [[String: Any]]
        else {
            XCTFail("Unable to fetch debug payload")
            return
        }

        XCTAssertTrue(keys.contains { ($0["uri_hash"] as? String) == keyIdentifier })

        player.stop()
    }

    private func waitForRenditions(_ player: ProxyHLSPlayer) async throws {
        for _ in 0..<30 {
            if !player.audioRenditions.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for renditions")
    }

}

private final class MockOriginServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockOriginServer")
    private var listener: NWListener?
    private let manifest: String
    private let segments: [String: Data]
    let mediaSequence: Int
    let segmentSize: Int

    init(
        segmentCount: Int = 1,
        mediaSequence: Int = 1,
        segmentDuration: TimeInterval = 4,
        segmentSize: Int = 1_024,
        keyURI: URL? = nil
    ) throws {
        self.mediaSequence = mediaSequence
        self.segmentSize = segmentSize

        var manifestLines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(segmentDuration))",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)"
        ]

        if let keyURI {
            manifestLines.append("#EXT-X-KEY:METHOD=AES-128,URI=\"\(keyURI.absoluteString)\",IV=0x1")
        }

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

private final class AdaptiveMockOriginServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AdaptiveMockOriginServer")
    private var listener: NWListener?
    private let segmentCount: Int
    private let failureAfterSequence: Int
    private let segmentDuration: TimeInterval
    private let segmentSize: Int
    private var lowSegmentRequests = 0
    private let includeAlternateRenditions: Bool
    private let audioPlaylistPath = "/audio-en.m3u8"
    private let subtitlePlaylistPath = "/subs-en.m3u8"
    private var audioSegments: [String: Data] = [:]
    private var audioPlaylist: String = ""
    private var subtitleSegments: [String: Data] = [:]
    private var subtitlePlaylist: String = ""

    init(
        segmentCount: Int = 4,
        failureAfterSequence: Int = 2,
        segmentDuration: TimeInterval = 2,
        segmentSize: Int = 512,
        includeAlternateRenditions: Bool = false
    ) {
        self.segmentCount = segmentCount
        self.failureAfterSequence = failureAfterSequence
        self.segmentDuration = segmentDuration
        self.segmentSize = segmentSize
        self.includeAlternateRenditions = includeAlternateRenditions
        if includeAlternateRenditions {
            let audioResources = AdaptiveMockOriginServer.makeAudioResources(segmentCount: segmentCount)
            audioPlaylist = audioResources.playlist
            audioSegments = audioResources.segments
            let subtitleResources = AdaptiveMockOriginServer.makeSubtitleResources()
            subtitlePlaylist = subtitleResources.playlist
            subtitleSegments = subtitleResources.segments
        }
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

    func didServeLowVariant() -> Bool {
        queue.sync { lowSegmentRequests > 0 }
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

        switch path {
        case "/master.m3u8":
            return HTTPResponse.text(masterManifest, contentType: "application/x-mpegURL").encoded()
        case "/high.m3u8":
            return HTTPResponse.text(variantManifest(prefix: "high"), contentType: "application/x-mpegURL").encoded()
        case "/low.m3u8":
            return HTTPResponse.text(variantManifest(prefix: "low"), contentType: "application/x-mpegURL").encoded()
        default:
            break
        }

        if includeAlternateRenditions && path == audioPlaylistPath {
            return HTTPResponse.text(audioPlaylist, contentType: "application/x-mpegURL").encoded()
        }

        if includeAlternateRenditions && path == subtitlePlaylistPath {
            return HTTPResponse.text(subtitlePlaylist, contentType: "application/x-mpegURL").encoded()
        }

        if path.hasPrefix("/high-seq-") {
            let sequence = sequenceNumber(from: String(path))
            if let sequence, sequence >= failureAfterSequence {
                return HTTPResponse(status: .serviceUnavailable).encoded()
            }
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "video/mp2t"],
                body: segmentBody(prefix: "high")
            ).encoded()
        }

        if path.hasPrefix("/low-seq-") {
            lowSegmentRequests += 1
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "video/mp2t"],
                body: segmentBody(prefix: "low")
            ).encoded()
        }

        if includeAlternateRenditions, let data = audioSegments[String(path)] {
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "audio/aac"],
                body: data
            ).encoded()
        }

        if includeAlternateRenditions, let data = subtitleSegments[String(path)] {
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "text/vtt"],
                body: data
            ).encoded()
        }

        return HTTPResponse(status: .notFound).encoded()
    }

    private var masterManifest: String {
        var lines: [String] = ["#EXTM3U"]
        if includeAlternateRenditions {
            lines.append("""
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-main",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioPlaylistPath)"
            """)
            lines.append("""
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs-main",NAME="English CC",LANGUAGE="en",AUTOSELECT=YES,FORCED=NO,URI="\(subtitlePlaylistPath)"
            """)
        }
        var streamAttributesHigh = "BANDWIDTH=2000000,AVERAGE-BANDWIDTH=1800000,RESOLUTION=1280x720"
        var streamAttributesLow = "BANDWIDTH=800000,AVERAGE-BANDWIDTH=700000,RESOLUTION=640x360"
        if includeAlternateRenditions {
            streamAttributesHigh += ",AUDIO=\"audio-main\",SUBTITLES=\"subs-main\""
            streamAttributesLow += ",AUDIO=\"audio-main\",SUBTITLES=\"subs-main\""
        }
        lines.append("#EXT-X-STREAM-INF:\(streamAttributesHigh)")
        lines.append("/high.m3u8")
        lines.append("#EXT-X-STREAM-INF:\(streamAttributesLow)")
        lines.append("/low.m3u8")
        return lines.joined(separator: "\n")
    }

    private func variantManifest(prefix: String) -> String {
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(segmentDuration))",
            "#EXT-X-MEDIA-SEQUENCE:1"
        ]
        for index in 0..<segmentCount {
            let sequence = index + 1
            lines.append("#EXTINF:\(segmentDuration),")
            lines.append("/\(prefix)-seq-\(sequence).ts")
        }
        return lines.joined(separator: "\n")
    }

    private func segmentBody(prefix: String) -> Data {
        Data(repeating: prefix == "high" ? 0xA1 : 0xB2, count: segmentSize)
    }

    private func sequenceNumber(from path: String) -> Int? {
        let components = path
            .replacingOccurrences(of: ".ts", with: "")
            .split(separator: "-")
        guard let last = components.last else { return nil }
        return Int(last)
    }

    private static func makeAudioResources(segmentCount: Int) -> (playlist: String, segments: [String: Data]) {
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:4",
            "#EXT-X-MEDIA-SEQUENCE:1"
        ]
        var storage: [String: Data] = [:]
        for index in 0..<segmentCount {
            let sequence = index + 1
            let path = "/audio-en-seq-\(sequence).aac"
            lines.append("#EXTINF:4,")
            lines.append(path)
            storage[path] = Data(repeating: 0xC0, count: 256)
        }
        lines.append("#EXT-X-ENDLIST")
        return (lines.joined(separator: "\n"), storage)
    }

    private static func makeSubtitleResources() -> (playlist: String, segments: [String: Data]) {
        let segmentPath = "/subs-en-1.vtt"
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:10,
        \(segmentPath)
        #EXT-X-ENDLIST
        """
        let body = """
        WEBVTT

        00:00.000 --> 00:05.000
        Hello world
        """
        return (playlist, [segmentPath: Data(body.utf8)])
    }
}

#endif
