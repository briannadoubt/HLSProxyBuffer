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
        player.play()
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
#endif
