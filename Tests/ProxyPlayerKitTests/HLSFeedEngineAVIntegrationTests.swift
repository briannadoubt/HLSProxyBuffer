#if canImport(AVFoundation) && canImport(Network)
import AVFoundation
import Foundation
import XCTest
@testable import HLSCore
@testable import ProxyPlayerKit

@MainActor
final class HLSFeedEngineAVIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] != nil, environment["RUN_PROXY_AV_TESTS"] == nil {
            throw XCTSkip("Feed AV integration tests are disabled on CI agents unless RUN_PROXY_AV_TESTS=1.")
        }
    }

    func testFocusHandoffKeepsWarmAVPlayerAndCurrentItemIntact() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }

        var policy = FeedPlaybackPolicy.preset(.shortFormFeed)
        policy.prefetch.aheadItemCount = 1
        policy.prefetch.behindItemCount = 0
        policy.budget.maximumResidentItems = 2
        policy.concurrency.maximumPlayerCount = 2
        policy.eviction.usesDiskCache = false
        policy.eviction.offscreenGracePeriod = 0
        policy.budget.diskCacheBytes = 0
        policy = try policy.validated()

        let cache = HLSSegmentCache(
            capacityBytes: policy.budget.memoryCacheBytes,
            diskCapacityBytes: 0,
            maximumEntryCount: policy.budget.maximumCacheEntryCount
        )
        let backend = try HLSFeedPreparationBackend(
            policy: policy,
            allowsInsecureManifests: true,
            cache: cache
        )
        let items = [
            FeedPlaybackItem(
                id: "short-a",
                source: .stream(
                    url: origin.fixturePlaylistURL(named: "short-a"),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 1_024 * 1_024
            ),
            FeedPlaybackItem(
                id: "short-b",
                source: .stream(
                    url: origin.fixturePlaylistURL(named: "short-b"),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 1_024 * 1_024
            ),
        ]
        let coordinator = try FeedCoordinator(items: items, policy: policy, backend: backend)
        let engine = try HLSFeedEngine(
            items: items,
            policy: policy,
            coordinator: coordinator,
            sessionFactory: { configuration in
                InsecureFeedPlayerSession(configuration: configuration, cache: cache)
            }
        )

        try await engine.update(signal(generation: 1, focused: items[0].id))
        var snapshot = await engine.waitUntilSettled()
        XCTAssertEqual(
            snapshot.activeItemID,
            items[0].id,
            "initial playback failures: \(snapshot.failures)"
        )
        XCTAssertEqual(
            snapshot.audibleItemID,
            items[0].id,
            "initial playback failures: \(snapshot.failures)"
        )
        let initiallyFocusedPlayer = try XCTUnwrap(engine.platformPlayer(for: items[0].id))
        XCTAssertFalse(initiallyFocusedPlayer.isMuted)
        XCTAssertEqual(
            snapshot.playback(for: items[1].id)?.phase,
            .warm,
            "neighbor preparation failures: \(snapshot.failures)"
        )

        let warmedPlayer = try XCTUnwrap(engine.platformPlayer(for: items[1].id))
        let warmedItem = try XCTUnwrap(warmedPlayer.currentItem)
        XCTAssertEqual(snapshot.playback(for: items[1].id)?.state.status, .ready)
        XCTAssertTrue(
            isEffectivelyMuted(warmedPlayer),
            "the prepared neighbor must remain silent"
        )

        try await engine.update(signal(generation: 2, focused: items[1].id))
        XCTAssertEqual(
            engine.snapshot.activeItemID, items[1].id,
            "A prerolled warm handoff must not await an expanded preparation request; buffered=\(warmedItem.loadedTimeRanges)"
        )
        snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.activeItemID, items[1].id)
        XCTAssertEqual(snapshot.audibleItemID, items[1].id)
        XCTAssertTrue(engine.platformPlayer(for: items[1].id) === warmedPlayer)
        XCTAssertTrue(warmedPlayer.currentItem === warmedItem)
        XCTAssertFalse(warmedPlayer.isMuted)
        XCTAssertGreaterThan(warmedPlayer.volume, 0)
        XCTAssertTrue(
            isEffectivelyMuted(initiallyFocusedPlayer),
            "Retired player: muted=\(initiallyFocusedPlayer.isMuted), volume=\(initiallyFocusedPlayer.volume), rate=\(initiallyFocusedPlayer.rate)"
        )
        XCTAssertEqual(snapshot.playback(for: items[1].id)?.phase, .focused)
        XCTAssertEqual(snapshot.maximumObservedPoolOccupancy, 2)
        XCTAssertEqual(snapshot.maximumObservedAudiblePlaybackCount, 1)
        let requests = origin.timelineSnapshot().filter { $0.kind == .requestStarted }
        XCTAssertEqual(
            requests.filter { $0.path == "/short-a/segment-000.m4s" }.count,
            1,
            "the first player must reuse preparation's shared segment cache"
        )
        XCTAssertEqual(
            requests.filter { $0.path == "/short-b/segment-000.m4s" }.count,
            1,
            "the warmed player must reuse preparation's shared segment cache"
        )

        await engine.stop()
        XCTAssertTrue(isEffectivelyMuted(warmedPlayer))
    }

    func testPrimingWaitsForPlayerConstructionAndCancelsPromptly() async throws {
        let player = ProxyHLSPlayer()
        var completed = false
        let preparation = Task { @MainActor in
            let result = await player.prepareForImmediatePlayback(retryPolicy: .automaticFeed)
            completed = true
            return result
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(player.player)
        XCTAssertFalse(completed, "An absent player during startup is not a terminal failure")
        let cancelledAt = ContinuousClock.now
        preparation.cancel()
        let didPrepare = await preparation.value
        XCTAssertFalse(didPrepare)
        XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(250))
        await player.stopAndWait()
    }

    func testNewNativePlayerStartsOfflineFromValidWarmDiskCache() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        defer { origin.stop() }
        let item = FeedPlaybackItem(
            id: "disk-revisit",
            source: .stream(url: origin.fixturePlaylistURL(named: "short-a"), kind: .videoOnDemand),
            estimatedPreparationBytes: 1_024 * 1_024
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hls-native-disk-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var policy = FeedPlaybackPolicy.shortFormFeed
        policy.eviction.diskDirectory = directory
        policy.retry.manifest = .init(maxAttempts: 1, retryDelay: 0)
        policy.retry.segment = .init(maxAttempts: 1)
        let online = try HLSFeedEngine(
            items: [item], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP
        )
        try await online.update(signal(generation: 1, focused: item.id))
        _ = await online.waitUntilSettled()
        XCTAssertTrue(online.snapshot.failures.isEmpty)
        let onlinePlayer = try XCTUnwrap(online.platformPlayer(for: item.id))
        let onlineDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while onlinePlayer.timeControlStatus != .playing, ContinuousClock.now < onlineDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(onlinePlayer.timeControlStatus, .playing)
        await online.stop()
        XCTAssertEqual(origin.timelineSnapshot().filter {
            $0.kind == .requestStarted && $0.path == "/short-a/playlist.m3u8"
        }.count, 1, "Preparation and playback must share the same valid manifest bytes")
        origin.stop()

        let relaunched = try HLSFeedEngine(
            items: [item], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP
        )
        try await relaunched.update(signal(generation: 1, focused: item.id))
        _ = await relaunched.waitUntilSettled()
        XCTAssertTrue(relaunched.snapshot.failures.isEmpty, "\(relaunched.snapshot.failures)")
        XCTAssertEqual(relaunched.snapshot.activeItemID, item.id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while relaunched.snapshot.playback(for: item.id)?.hasStartedPlayback != true,
              relaunched.snapshot.failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(relaunched.snapshot.playback(for: item.id)?.hasStartedPlayback, true)
        await relaunched.stop()
    }

    func testOfflineColdCacheDoesNotPretendToStartNativePlayback() async throws {
        let origin = try FeedFixtureOrigin()
        try await origin.start()
        let url = origin.fixturePlaylistURL(named: "short-a")
        origin.stop()
        let item = FeedPlaybackItem(
            id: "cold-offline", source: .stream(url: url, kind: .videoOnDemand),
            estimatedPreparationBytes: 1_024 * 1_024
        )
        var policy = FeedPlaybackPolicy.shortFormFeed
        policy.eviction.usesDiskCache = false
        policy.retry.manifest = .init(maxAttempts: 1, retryDelay: 0)
        let engine = try HLSFeedEngine(
            items: [item], policy: policy, sourceTransportPolicy: .allowLoopbackHTTP
        )
        try await engine.update(signal(generation: 1, focused: item.id))
        let snapshot = await engine.waitUntilSettled()
        XCTAssertFalse(snapshot.failures.isEmpty)
        XCTAssertNil(snapshot.activeItemID)
        XCTAssertNil(snapshot.audibleItemID)
        await engine.stop()
    }

    private func signal(
        generation: UInt64,
        focused: FeedItemID
    ) -> FeedViewportSignal {
        FeedViewportSignal(
            generation: .init(rawValue: generation),
            focusedItemID: focused,
            visibleItems: [.init(
                itemID: focused,
                fraction: 1,
                distanceInViewports: 0
            )],
            velocityInViewportsPerSecond: 6,
            observedAt: .milliseconds(Int64(generation))
        )
    }

    private func isEffectivelyMuted(_ player: AVPlayer) -> Bool {
        player.isMuted || player.volume == 0
    }
}

@MainActor
private final class InsecureFeedPlayerSession: HLSFeedPlayerSession {
    private let player: ProxyHLSPlayer

    var state: PlayerState { player.state }
    var feedPlatformPlayer: AVPlayer? { player.player }

    init(configuration: ProxyPlayerConfiguration, cache: HLSSegmentCache) {
        var configuration = configuration
        configuration.allowInsecureManifests = true
        configuration.bufferPolicy.hideUntilBuffered = false
        configuration.bufferPolicy.refreshInterval = 30
        player = ProxyHLSPlayer(configuration: configuration, sharedCache: cache)
    }

    func stateUpdates() -> AsyncStream<PlayerState> { player.stateUpdates() }

    func load(
        from remoteURL: URL,
        quality: HLSRewriteConfiguration.QualityPolicy
    ) async {
        await player.load(from: remoteURL, quality: quality)
    }

    func load(clips: [ProxyPlaybackClip]) async throws { try await player.load(clips: clips) }
    func prepareForImmediatePlayback(
        retryPolicy: HLSFeedPlayerPreparationRetryPolicy
    ) async -> Bool {
        await player.prepareForImmediatePlayback(retryPolicy: retryPolicy)
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func setMuted(_ isMuted: Bool) { player.setFeedPlaybackMuted(isMuted) }
    func setPlaybackRate(_ rate: Float) { player.setPlaybackRate(rate) }
    func jumpToLive() async throws { try await player.jumpToLive() }
    func seek(secondsBehindLiveEdge: TimeInterval) async throws {
        try await player.seek(secondsBehindLiveEdge: secondsBehindLiveEdge)
    }

    func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async {
        var configuration = configuration
        configuration.allowInsecureManifests = true
        configuration.bufferPolicy.hideUntilBuffered = false
        configuration.bufferPolicy.refreshInterval = 30
        await player.updateConfiguration(configuration)
    }

    func stopAndWait() async { await player.stopAndWait() }

    func restartPlayback() async {
        guard let avPlayer = player.player else { return }
        avPlayer.currentItem?.cancelPendingSeeks()
        await avPlayer.seek(to: .zero)
        player.play()
    }
}
#endif
