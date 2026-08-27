#if canImport(AVFoundation) && canImport(Network)
import XCTest
import Foundation
import AVFoundation
import Network
@testable import ProxyPlayerKit
@testable import HLSCore
@testable import LocalProxy

@MainActor
final class ProxyPlayerKitAVIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        if shouldSkipIntegrationTests {
            throw XCTSkip("ProxyPlayerKit AV integration tests are disabled on CI agents (set RUN_PROXY_AV_TESTS=1 to force-enable).")
        }
    }

    func testAVPlayerHitsProxyPlaylistAndSegments() async throws {
        let origin = try MockOriginServer()
        try await origin.start()
        try await waitForOriginReachability(origin.manifestURL)
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

        await player.stopAndWait()
    }

    func testOnePlayerHandsOffBetweenVODAndLiveAndClearsDVRState() async throws {
        let vodOrigin = try MockOriginServer(segmentCount: 3, segmentDuration: 1)
        let liveOrigin = try MockOriginServer(
            segmentCount: 4,
            segmentDuration: 1,
            isLive: true
        )
        try await vodOrigin.start()
        try await liveOrigin.start()
        defer {
            vodOrigin.stop()
            liveOrigin.stop()
        }
        let player = ProxyHLSPlayer(configuration: .init(
            bufferPolicy: .init(
                targetBufferSeconds: 1,
                maxPrefetchSegments: 2,
                hideUntilBuffered: false,
                refreshInterval: 30
            ),
            allowInsecureManifests: true
        ))

        await player.load(from: vodOrigin.manifestURL)
        let avPlayer = try XCTUnwrap(player.player)
        let firstItem = try XCTUnwrap(avPlayer.currentItem)
        XCTAssertNil(player.livePlayback)
        do {
            try await player.jumpToLive()
            XCTFail("VOD must reject jump-to-live")
        } catch {
            XCTAssertEqual(error as? LivePlaybackControlError, .notLive)
        }

        await player.load(from: liveOrigin.manifestURL)
        XCTAssertTrue(player.player === avPlayer)
        XCTAssertFalse(player.player?.currentItem === firstItem)
        XCTAssertEqual(player.livePlayback?.window?.mediaSequenceRange, 1...4)

        let liveItem = try XCTUnwrap(player.player?.currentItem)
        await player.load(from: vodOrigin.manifestURL)
        XCTAssertTrue(player.player === avPlayer)
        XCTAssertFalse(player.player?.currentItem === liveItem)
        XCTAssertNil(player.livePlayback)

        await player.stopAndWait()
    }

    func testLiveFixtureSupportsDVRSeekAndJumpToLiveOnOneAVPlayerItem() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        let player = ProxyHLSPlayer(configuration: .init(
            bufferPolicy: .init(
                targetBufferSeconds: 1,
                maxPrefetchSegments: 3,
                hideUntilBuffered: false,
                refreshInterval: 30
            ),
            allowInsecureManifests: true
        ))

        await player.load(from: origin.fixturePlaylistURL(named: "live"))
        player.play()
        let item = try XCTUnwrap(player.player?.currentItem)
        let duration = try XCTUnwrap(player.livePlayback?.window?.durationSeconds)
        let request = min(1, duration / 2)

        try await player.seek(secondsBehindLiveEdge: request)
        XCTAssertTrue(player.player?.currentItem === item)
        XCTAssertEqual(
            player.player?.currentTime().seconds ?? .nan,
            duration - request,
            accuracy: 0.25
        )
        XCTAssertEqual(
            player.livePlayback?.liveEdgeDistanceSeconds ?? .nan,
            request,
            accuracy: 0.25
        )

        try await player.jumpToLive()
        XCTAssertTrue(player.player?.currentItem === item)
        XCTAssertNotNil(player.livePlayback)
        await player.stopAndWait()
    }

    func testCompatibleClipsInstallOneProxyTimelineAndServeAcrossBoundary() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        let player = ProxyHLSPlayer(configuration: .init(
            bufferPolicy: .init(
                targetBufferSeconds: 2,
                maxPrefetchSegments: 2,
                hideUntilBuffered: false
            ),
            allowInsecureManifests: true
        ))
        let clips = ["short-a", "short-b"].map { name in
            ProxyPlaybackClip(
                id: name,
                playlistURL: origin.fixturePlaylistURL(named: name),
                mediaSignature: Self.compatibleClipSignature
            )
        }

        try await player.load(clips: clips)
        XCTAssertNotNil(player.player?.currentItem)
        XCTAssertNil(player.clipStitchingError)
        let masterURL = try XCTUnwrap(player.playlistURL())
        let master = String(decoding: try await URLSession.shared.data(from: masterURL).0, as: UTF8.self)
        XCTAssertFalse(master.contains(origin.baseURL.absoluteString))
        let variantLine = try XCTUnwrap(master.split(separator: "\n").last { !$0.hasPrefix("#") })
        let variantURL = try XCTUnwrap(URL(string: String(variantLine)))
        let variant = String(decoding: try await URLSession.shared.data(from: variantURL).0, as: UTF8.self)

        XCTAssertFalse(variant.contains(origin.baseURL.absoluteString))
        XCTAssertTrue(variant.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(variant.contains("#EXT-X-DISCONTINUITY-SEQUENCE:0"))
        XCTAssertEqual(
            variant.split(separator: "\n").filter { $0 == "#EXT-X-DISCONTINUITY" }.count,
            1
        )
        let boundary = try XCTUnwrap(variant.range(of: "#EXT-X-DISCONTINUITY"))
        let boundarySegment = try XCTUnwrap(variant.range(of: "/segments/segment-3-"))
        XCTAssertLessThan(boundary.lowerBound, boundarySegment.lowerBound)

        let lines = variant.split(separator: "\n").map(String.init)
        let segmentURLs = try lines
            .filter { !$0.hasPrefix("#") && $0.hasPrefix("http://") }
            .map { try XCTUnwrap(URL(string: $0)) }
        let mapURLs = try lines
            .filter { $0.hasPrefix("#EXT-X-MAP:") }
            .map { try XCTUnwrap(quotedURI(in: $0)) }
        XCTAssertEqual(segmentURLs.count, 6)
        XCTAssertEqual(mapURLs.count, 2)
        XCTAssertTrue(segmentURLs.allSatisfy { $0.pathExtension == "m4s" })
        XCTAssertTrue(mapURLs.allSatisfy { $0.pathExtension == "mp4" })
        for url in mapURLs + segmentURLs {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(data.isEmpty, "Expected proxied bytes for \(url)")
        }

        let firstItem = player.player?.currentItem
        let incompatible = ProxyPlaybackClip(
            id: "short-b-hevc",
            playlistURL: origin.fixturePlaylistURL(named: "short-b"),
            mediaSignature: Self.incompatibleClipSignature
        )
        do {
            try await player.load(clips: [clips[0], incompatible])
            XCTFail("Incompatible clips must fail before proxy catalog replacement")
        } catch {
            XCTAssertEqual(
                error as? HLSClipStitchingError,
                .incompatibleMediaSignature(clipIndex: 1)
            )
        }
        XCTAssertEqual(player.clipStitchingError, .incompatibleMediaSignature(clipIndex: 1))
        XCTAssertNotNil(firstItem)
        XCTAssertNil(player.player?.currentItem, "The superseded item must not continue playback after failure")
        await player.stopAndWait()
    }

    func testPlaybackRateSurvivesPauseAndItemReplacement() async throws {
        let origin = try MockOriginServer()
        try await origin.start()
        try await waitForOriginReachability(origin.manifestURL)
        defer { origin.stop() }

        let configuration = ProxyPlayerConfiguration(
            bufferPolicy: .init(targetBufferSeconds: 2, maxPrefetchSegments: 2, hideUntilBuffered: false),
            allowInsecureManifests: true
        )
        let player = ProxyHLSPlayer(configuration: configuration)
        player.setPlaybackRate(1.5)
        player.play()

        await player.load(from: origin.manifestURL)
        let firstItem = try XCTUnwrap(player.player?.currentItem)
        XCTAssertEqual(player.player?.defaultRate, 1.5)
        XCTAssertEqual(player.playbackRate, 1.5)

        player.pause()
        XCTAssertEqual(player.player?.rate, 0)
        XCTAssertEqual(player.playbackRate, 1.5)

        await player.load(from: origin.manifestURL)
        let replacementItem = try XCTUnwrap(player.player?.currentItem)
        XCTAssertFalse(firstItem === replacementItem)
        XCTAssertEqual(player.player?.defaultRate, 1.5)
        XCTAssertEqual(player.player?.rate, 0)

        player.play()
        XCTAssertEqual(player.player?.defaultRate, 1.5)
        await player.stopAndWait()
    }

    func testSwitchesVariantsAfterFailures() async throws {
        let origin = AdaptiveMockOriginServer()
        try await origin.start()
        try await waitForOriginReachability(origin.manifestURL)
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
        player.play()

        // The mock segment bytes are intentionally minimal and AVPlayer may wait
        // before requesting them. Fetch the first proxy segment directly so this
        // integration test deterministically establishes a playback boundary.
        let initialSegmentURL = try await firstSegmentURL(for: player)
        let (initialSegmentData, _) = try await URLSession.shared.data(from: initialSegmentURL)
        XCTAssertFalse(initialSegmentData.isEmpty)

        await fulfillment(of: [switchedExpectation], timeout: 20)

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

        await player.stopAndWait()
    }

    func testExposesAlternateRenditionsAndSelection() async throws {
        let origin = AdaptiveMockOriginServer(includeAlternateRenditions: true)
        try await origin.start()
        try await waitForOriginReachability(origin.manifestURL)
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

        await player.stopAndWait()
    }

    func testSupplementalMasterResourcesStayOnLoopback() async throws {
        let origin = AdaptiveMockOriginServer(includeSupplementalResources: true)
        try await origin.start()
        try await waitForOriginReachability(origin.manifestURL)
        defer { origin.stop() }
        let player = ProxyHLSPlayer(configuration: .init(allowInsecureManifests: true))

        await player.load(from: origin.manifestURL)
        let masterURL = try XCTUnwrap(player.playlistURL())
        let master = String(decoding: try await URLSession.shared.data(from: masterURL).0, as: UTF8.self)
        XCTAssertFalse(master.contains("EXT-X-CONTENT-STEERING"))
        XCTAssertFalse(master.contains(origin.manifestURL.deletingLastPathComponent().absoluteString))

        let iframeLine = try XCTUnwrap(master.split(separator: "\n").first {
            $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
        })
        let metadataLine = try XCTUnwrap(master.split(separator: "\n").first {
            $0.hasPrefix("#EXT-X-SESSION-DATA:")
        })
        let iframeURL = try XCTUnwrap(quotedURI(in: String(iframeLine)))
        let metadataURL = try XCTUnwrap(quotedURI(in: String(metadataLine)))
        XCTAssertEqual(iframeURL.host, "127.0.0.1")
        XCTAssertEqual(metadataURL.host, "127.0.0.1")

        let (iframeData, iframeResponse) = try await URLSession.shared.data(from: iframeURL)
        let iframePlaylist = String(decoding: iframeData, as: UTF8.self)
        XCTAssertTrue(
            iframePlaylist.contains("/segments/"),
            "Expected rewritten I-frame playlist; URL=\(iframeURL), status=\((iframeResponse as? HTTPURLResponse)?.statusCode ?? -1), body=\(iframePlaylist), master=\(master)"
        )
        XCTAssertFalse(iframePlaylist.contains("/iframe-1.m4s"))
        var metadataRequest = URLRequest(url: metadataURL)
        metadataRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (metadata, metadataResponse) = try await URLSession.shared.data(for: metadataRequest)
        XCTAssertEqual(
            String(decoding: metadata, as: UTF8.self),
            "{\"title\":\"fixture\"}",
            "URL=\(metadataURL), status=\((metadataResponse as? HTTPURLResponse)?.statusCode ?? -1), master=\(master)"
        )
        await player.stopAndWait()
    }

    func testRewritesKeysInProxyMode() async throws {
        let keyURL = URL(string: "skd://asset/12345")!
        let origin = try MockOriginServer(keyURI: keyURL)
        try await origin.start()
        try await waitForOriginReachability(origin.manifestURL)
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

        await player.stopAndWait()
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

    private func firstSegmentURL(for player: ProxyHLSPlayer) async throws -> URL {
        guard let playlistURL = player.playlistURL() else {
            throw URLError(.badURL)
        }
        let (masterData, _) = try await URLSession.shared.data(from: playlistURL)
        guard
            let masterString = String(data: masterData, encoding: .utf8),
            let variantLine = masterString
                .split(separator: "\n")
                .last(where: { !$0.hasPrefix("#") }),
            let variantURL = URL(string: String(variantLine))
        else {
            throw URLError(.cannotParseResponse)
        }
        let (variantData, _) = try await URLSession.shared.data(from: variantURL)
        guard
            let playlistString = String(data: variantData, encoding: .utf8),
            let segmentLine = playlistString
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("http://") }),
            let segmentURL = URL(string: String(segmentLine))
        else {
            throw URLError(.cannotParseResponse)
        }
        return segmentURL
    }

    private static let compatibleClipSignature = HLSClipMediaSignature(
        container: .fragmentedMP4,
        codecs: ["avc1.640028", "mp4a.40.2"],
        tracks: [
            .init(kind: .video, codec: "avc1.640028"),
            .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
        ],
        videoRange: "SDR",
        segmentsAreIndependent: true
    )

    private static let incompatibleClipSignature = HLSClipMediaSignature(
        container: .fragmentedMP4,
        codecs: ["hvc1.2.4.L123.B0", "mp4a.40.2"],
        tracks: [
            .init(kind: .video, codec: "hvc1.2.4.L123.B0"),
            .init(kind: .audio, codec: "mp4a.40.2", layout: "stereo"),
        ],
        videoRange: "SDR",
        segmentsAreIndependent: true
    )

}

private func quotedURI(in tag: String) -> URL? {
    guard let start = tag.range(of: "URI=\"")?.upperBound,
          let end = tag[start...].firstIndex(of: "\"") else { return nil }
    return URL(string: String(tag[start..<end]))
}

private func waitForOriginReachability(_ url: URL, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return
            }
        } catch {
            // Ignore and retry until timeout.
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("Origin server at \(url) not reachable within \(timeout)s")
    throw URLError(.cannotConnectToHost)
}

private var shouldSkipIntegrationTests: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["CI"] != nil && env["RUN_PROXY_AV_TESTS"] == nil
}
#endif
