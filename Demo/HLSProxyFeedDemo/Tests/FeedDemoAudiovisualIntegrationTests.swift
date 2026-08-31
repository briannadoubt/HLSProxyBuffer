import AVFoundation
import XCTest
@testable import HLSProxyFeedDemo
@testable import ProxyPlayerKit

@MainActor
final class FeedDemoAudiovisualIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["CI"] != nil,
           ProcessInfo.processInfo.environment["RUN_PROXY_AV_TESTS"] == nil {
            throw XCTSkip("Native AVPlayer opt-in on hosted CI; real swipe UI runs there independently")
        }
    }

    func testBothRealRenditionsAdvanceDecodedFramesAndKeepRetiredPlayersSilent() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let clips = try [FeedDemoMediaLibrary.Clip.Kind.liveAction, .animation].map { kind in
            try XCTUnwrap(library.shortClips.first { $0.kind == kind })
        }
        var qualifiedEngines: [HLSFeedEngine] = []
        for renditionID in ["360p", "720p"] {
            let items = try clips.map { clip in
                let rendition = try XCTUnwrap(clip.renditions.first { $0.id == renditionID })
                return FeedPlaybackItem(
                    id: FeedItemID(rawValue: clip.id),
                    source: .stream(url: baseURL.appendingPathComponent(
                        library.catalog.corpusVersion + "/" + rendition.playlistPath
                    ), kind: .videoOnDemand),
                    estimatedPreparationBytes: 2 * 1_024 * 1_024
                )
            }
            var policy = FeedPlaybackPolicy.shortFormFeed
            policy.eviction.usesDiskCache = false
            policy.eviction.offscreenGracePeriod = 0
            let engine = try HLSFeedEngine(items: items, policy: policy, sourceTransportPolicy: .allowLoopbackHTTP)
            qualifiedEngines.append(engine)
            do {
                var retained: [AVPlayer] = []
                var retainedItems: [AVPlayerItem] = []
                for (generation, index) in [0, 1, 0].enumerated() {
                    let before = decodedFrameCount(engine)
                    try await engine.update(signal(generation: generation + 1, item: items[index].id))
                    _ = await engine.waitUntilSettled()
                    XCTAssertTrue(engine.snapshot.failures.isEmpty, "\(engine.snapshot.failures)")
                    let player = try XCTUnwrap(engine.platformPlayer(for: items[index].id))
                    retained.append(player)
                    let item = try XCTUnwrap(player.currentItem)
                    if !retainedItems.contains(where: { $0 === item }) { retainedItems.append(item) }
                    XCTAssertLessThanOrEqual(retainedItems.reduce(0) { count, item in
                        count + item.outputs.filter { $0 is AVPlayerItemVideoOutput }.count
                    }, 1, "Only the focused lease may retain a sampling output")
                    // HLS AVURLAsset track loading may return an empty array;
                    // the ready AVPlayerItem exposes its selected native tracks.
                    let tracks = item.tracks.compactMap(\.assetTrack)
                    let videoTracks = tracks.filter { $0.mediaType == .video }
                    let audioTracks = tracks.filter { $0.mediaType == .audio }
                    XCTAssertEqual(audioTracks.count, 1)
                    XCTAssertEqual(videoTracks.count, 1)
                    let startedAt = player.currentTime().seconds
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while decodedFrameCount(engine) < before + 3, ContinuousClock.now < deadline {
                        assertAudioOwnership(engine, items: items)
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    XCTAssertGreaterThanOrEqual(decodedFrameCount(engine), before + 3)
                    XCTAssertTrue(item.tracks.filter { $0.assetTrack?.mediaType == .audio }.allSatisfy(\.isEnabled))
                    XCTAssertEqual(Int(item.presentationSize.height), renditionID == "360p" ? 360 : 720)
                    XCTAssertGreaterThan(player.currentTime().seconds, startedAt)
                    XCTAssertEqual(engine.snapshot.activeItemID, items[index].id)
                    XCTAssertEqual(engine.snapshot.audibleItemID, items[index].id)
                }
                XCTAssertGreaterThan(engine.telemetry.snapshot.paths.reduce(0) {
                    $0 + ($1.advancingDecodedFrameCount ?? 0)
                }, 0)
                XCTAssertGreaterThan(engine.telemetry.snapshot.paths.reduce(0) {
                    $0 + ($1.decodedFirstFrameLatency?.count ?? 0)
                }, 0)
                _ = engine.setPlaybackSuspended(true)
                XCTAssertTrue(retained.allSatisfy { $0.isMuted || $0.volume == 0 })
                let suspendedFrames = decodedFrameCount(engine)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(decodedFrameCount(engine), suspendedFrames)
                _ = engine.setPlaybackSuspended(false)
                _ = await engine.waitUntilSettled()
                await engine.stop()
                XCTAssertTrue(retained.allSatisfy { ($0.isMuted || $0.volume == 0) && $0.rate == 0 })
                XCTAssertTrue(retainedItems.allSatisfy { $0.outputs.isEmpty })
                let stoppedCount = decodedFrameCount(engine)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(decodedFrameCount(engine), stoppedCount)
                XCTAssertGreaterThan(engine.telemetry.snapshot.nativeAudio?.sampleCount ?? 0, 0)
                XCTAssertEqual(engine.telemetry.snapshot.nativeAudio?.maximumEligiblePlayers, 1)
                XCTAssertEqual(engine.telemetry.snapshot.nativeAudio?.ownershipViolationCount, 0)
            } catch {
                await engine.stop()
                throw error
            }
        }
        try exportEvidence(
            name: "renditions", corpus: library.catalog.corpusVersion, engines: qualifiedEngines,
            scenarios: ["360p_native_playback", "720p_native_playback", "revisit", "focus_handoff", "suspend_resume", "retired_audio_teardown"],
            audioTrackChecks: 6
        )
    }

    private func assertAudioOwnership(_ engine: HLSFeedEngine, items: [FeedPlaybackItem]) {
        let eligible = items.filter {
            guard let player = engine.platformPlayer(for: $0.id), player.currentItem != nil else { return false }
            return !player.isMuted && player.volume > 0
        }
        XCTAssertLessThanOrEqual(eligible.count, 1)
        for item in eligible {
            XCTAssertEqual(item.id, engine.snapshot.activeItemID)
            XCTAssertEqual(item.id, engine.snapshot.targetFocusedItemID)
            XCTAssertEqual(item.id, engine.snapshot.audibleItemID)
        }
    }

    func testRealDecodedPlaybackAcrossColdWarmDiskOfflineMissAndPressure() async throws {
        let origin = try FeedDemoFixtureOrigin(configuration: .init(media: .real))
        let base = try await origin.start()
        defer { origin.stop() }
        let library = try XCTUnwrap(origin.library)
        let clips = Array(library.shortClips.prefix(2))
        let items = try clips.map { clip in
            let rendition = try XCTUnwrap(clip.renditions.first { $0.id == "360p" })
            return FeedPlaybackItem(id: FeedItemID(rawValue: clip.id), source: .stream(
                url: base.appendingPathComponent(library.catalog.corpusVersion + "/" + rendition.playlistPath),
                kind: .videoOnDemand
            ), estimatedPreparationBytes: 2 * 1_024 * 1_024)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-real-disk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = FeedPlaybackPolicy.shortFormFeed
        policy.eviction.diskDirectory = directory
        policy.retry.manifest = .init(maxAttempts: 1, retryDelay: 0)
        policy.retry.segment = .init(maxAttempts: 1)
        var engines: [HLSFeedEngine] = []
        do {
            let cold = try HLSFeedEngine(items: [items[0]], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP)
            engines.append(cold)
            try await cold.update(signal(generation: 1, item: items[0].id))
            try await requireAdvancing(cold, item: items[0].id)
            let coldOrigin = await origin.snapshot()
            XCTAssertGreaterThan(coldOrigin.responseByteCount, 0)
            await cold.stop()

            await origin.setOffline(true)
            let beforeWarm = await origin.snapshot()
            let warm = try HLSFeedEngine(items: [items[0]], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP)
            engines.append(warm)
            try await warm.update(signal(generation: 1, item: items[0].id))
            try await requireAdvancing(warm, item: items[0].id)
            let afterWarm = await origin.snapshot()
            XCTAssertEqual(afterWarm.requestCount, beforeWarm.requestCount,
                           "A new engine must use valid cached manifest/init/media bytes without duplicate origin requests")
            XCTAssertGreaterThan(warm.telemetry.snapshot.paths.reduce(0) { $0 + $1.cacheHitCount }, 0)
            await warm.handleMemoryPressure()
            try await requireAdvancing(warm, item: items[0].id)
            XCTAssertGreaterThan(warm.telemetry.snapshot.resources.evictionCounts[.memoryPressure, default: 0], 0)
            await warm.stop()

            let miss = try HLSFeedEngine(items: [items[1]], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP)
            engines.append(miss)
            try await miss.update(signal(generation: 1, item: items[1].id))
            _ = await miss.waitUntilSettled()
            XCTAssertFalse(miss.snapshot.failures.isEmpty, "An uncached offline item must fail visibly")
            XCTAssertEqual(decodedFrameCount(miss), 0)
            XCTAssertNil(miss.snapshot.audibleItemID)
            await miss.stop()

            await origin.setOffline(false)
            await origin.setNetworkProfile(.poor)
            let recovered = try HLSFeedEngine(items: [items[1]], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP)
            engines.append(recovered)
            try await recovered.update(signal(generation: 1, item: items[1].id))
            try await requireAdvancing(recovered, item: items[1].id)
            XCTAssertTrue(recovered.snapshot.failures.isEmpty)
            await recovered.stop()

            // Exercise real disk-budget eviction with a fresh, explicitly tiny
            // typed cache. Memory remains large enough for normal playback.
            await origin.setNetworkProfile(.unconstrained)
            var evictionPolicy = policy
            evictionPolicy.eviction.diskDirectory = directory.appendingPathComponent("eviction")
            evictionPolicy.budget.diskCacheBytes = 64 * 1_024
            let eviction = try HLSFeedEngine(items: [items[0]], policy: evictionPolicy, sourceTransportPolicy: .allowLoopbackHTTP)
            engines.append(eviction)
            try await eviction.update(signal(generation: 1, item: items[0].id))
            try await requireAdvancing(eviction, item: items[0].id)
            await eviction.handleMemoryPressure()
            XCTAssertLessThanOrEqual(eviction.telemetry.snapshot.resources.diskResidentBytes, evictionPolicy.budget.diskCacheBytes)
            XCTAssertGreaterThan(eviction.telemetry.snapshot.resources.evictionCounts[.diskByteLimit, default: 0], 0)
            await eviction.stop()
            try exportEvidence(
                name: "cache", corpus: library.catalog.corpusVersion, engines: engines,
                scenarios: ["cold_empty_cache", "new_engine_warm_disk", "offline_warm_reuse", "uncached_offline_failure", "memory_pressure", "poor_network_recovery", "disk_eviction"],
                audioTrackChecks: 0
            )
        } catch {
            for engine in engines { await engine.stop() }
            throw error
        }
    }

    private func requireAdvancing(_ engine: HLSFeedEngine, item: FeedItemID) async throws {
        _ = await engine.waitUntilSettled()
        let before = decodedFrameCount(engine)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while decodedFrameCount(engine) < before + 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(decodedFrameCount(engine), before + 3)
        XCTAssertTrue(engine.snapshot.playback(for: item)?.hasAdvancingVideoFrames == true)
        XCTAssertEqual(engine.snapshot.activeItemID, item)
        XCTAssertEqual(engine.snapshot.audibleItemID, item)
        XCTAssertEqual(engine.telemetry.snapshot.nativeAudio?.ownershipViolationCount, 0)
    }

    private func decodedFrameCount(_ engine: HLSFeedEngine) -> UInt64 {
        engine.telemetry.snapshot.paths.reduce(0) { $0 + ($1.decodedFrameCount ?? 0) }
    }

    private func exportEvidence(
        name: String, corpus: String, engines: [HLSFeedEngine], scenarios: [String], audioTrackChecks: Int
    ) throws {
        struct Evidence: Encodable {
            let schemaVersion = 1
            let qualificationKind = "real_audiovisual_native_playback"
            let corpusVersion: String
            let passed: Bool
            let scenarioIDs: [String]
            let decodedFrameCount: UInt64
            let nativeAudioTrackCheckCount: Int
            let nativeAudioOwnershipViolationCount: UInt64
        }
        let evidence = Evidence(
            corpusVersion: corpus, passed: testRun?.totalFailureCount == 0, scenarioIDs: scenarios,
            decodedFrameCount: engines.reduce(0) { $0 + decodedFrameCount($1) },
            nativeAudioTrackCheckCount: audioTrackChecks,
            nativeAudioOwnershipViolationCount: engines.reduce(0) {
                $0 + ($1.telemetry.snapshot.nativeAudio?.ownershipViolationCount ?? 0)
            }
        )
        let data = try JSONEncoder().encode(evidence)
        if let path = ProcessInfo.processInfo.environment["HLS_CI_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("hls-real-native-\(name).json"), options: .atomic)
        }
    }

    private func signal(generation: Int, item: FeedItemID) -> FeedViewportSignal {
        .init(generation: .init(rawValue: UInt64(generation)), focusedItemID: item,
              visibleItems: [.init(itemID: item, fraction: 1, distanceInViewports: 0)], observedAt: .zero)
    }
}
