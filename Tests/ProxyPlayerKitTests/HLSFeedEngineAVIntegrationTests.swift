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
        XCTAssertEqual(snapshot.activeItemID, items[0].id)
        XCTAssertEqual(snapshot.audibleItemID, items[0].id)
        let initiallyFocusedPlayer = try XCTUnwrap(engine.platformPlayer(for: items[0].id))
        XCTAssertFalse(initiallyFocusedPlayer.isMuted)
        XCTAssertEqual(snapshot.playback(for: items[1].id)?.phase, .warm)

        let warmedPlayer = try XCTUnwrap(engine.platformPlayer(for: items[1].id))
        let warmedItem = try XCTUnwrap(warmedPlayer.currentItem)
        XCTAssertEqual(snapshot.playback(for: items[1].id)?.state.status, .ready)
        XCTAssertTrue(
            isEffectivelyMuted(warmedPlayer),
            "the prepared neighbor must remain silent"
        )

        try await engine.update(signal(generation: 2, focused: items[1].id))
        snapshot = await engine.waitUntilSettled()

        XCTAssertEqual(snapshot.activeItemID, items[1].id)
        XCTAssertEqual(snapshot.audibleItemID, items[1].id)
        XCTAssertTrue(engine.platformPlayer(for: items[1].id) === warmedPlayer)
        XCTAssertTrue(warmedPlayer.currentItem === warmedItem)
        XCTAssertFalse(warmedPlayer.isMuted)
        XCTAssertGreaterThan(warmedPlayer.volume, 0)
        XCTAssertTrue(isEffectivelyMuted(initiallyFocusedPlayer))
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
    func prepareForImmediatePlayback() async -> Bool {
        await player.prepareForImmediatePlayback()
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
