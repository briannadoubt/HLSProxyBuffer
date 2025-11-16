import Foundation
import HLSCore
import LocalProxy
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Combine)
import Combine
#endif

#if canImport(Combine) && canImport(AVFoundation)
@MainActor
public final class ProxyHLSPlayer: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var state = PlayerState()
    @Published public private(set) var configuration: ProxyPlayerConfiguration

    private let logger: Logger
    private let parser = HLSParser()
    private let rewriter = HLSRewriter()
    private let cache: HLSSegmentCache
    private let scheduler: SegmentPrefetchScheduler
    private let playlistStore = PlaylistStore()
    private let auxiliaryStore = AuxiliaryAssetStore()
    private let router = ProxyRouter()
    private let segmentCatalog = SegmentCatalog()
    private let segmentFetcher: HLSSegmentFetcher
    private var currentPlaylist: MediaPlaylist?
    private var currentRewriteConfiguration: HLSRewriteConfiguration?
    private var didPreparePlayerForCurrentLoad = false
    private lazy var server = ProxyServer(router: router)
    private let diagnostics: ProxyPlayerDiagnostics

    public init(
        configuration: ProxyPlayerConfiguration = .init(),
        logger: Logger = ProxyPlayerLogger(),
        diagnostics: ProxyPlayerDiagnostics = .init()
    ) {
        self.configuration = configuration
        self.logger = logger
        self.diagnostics = diagnostics
        self.segmentFetcher = HLSSegmentFetcher(validationPolicy: configuration.segmentValidation)
        self.cache = HLSSegmentCache(
            capacity: configuration.cachePolicy.memoryCapacity,
            diskDirectory: ProxyHLSPlayer.diskDirectory(for: configuration.cachePolicy)
        )
        self.scheduler = SegmentPrefetchScheduler(configuration: .init(
            targetBufferSeconds: configuration.bufferPolicy.targetBufferSeconds,
            maxSegments: configuration.bufferPolicy.maxPrefetchSegments
        ))

        let playlistHandler = PlaylistHandler(store: playlistStore, onServe: diagnostics.onPlaylistServed)
        router.register(path: "/playlist.m3u8", handler: playlistHandler.makeHandler())

        let segmentHandler = SegmentHandler(
            cache: cache,
            catalog: segmentCatalog,
            fetcher: segmentFetcher,
            scheduler: scheduler,
            onSegmentServed: diagnostics.onSegmentServed
        )
        router.register(path: "/segments/*", handler: segmentHandler.makeHandler())

        let assetHandler = AuxiliaryAssetHandler(store: auxiliaryStore)
        router.register(path: "/assets/*", handler: assetHandler.makeHandler())

        router.register(path: "/debug/status", handler: makeDebugHandler())
        router.register(path: "/metrics", handler: metricsHandler())

        Task {
            await applyConfiguration()
        }
    }

    public func load(
        from remoteURL: URL,
        quality: HLSRewriteConfiguration.QualityPolicy = .automatic
    ) async {
        let resolvedQuality = resolveQualityPolicy(requested: quality)
        state = PlayerState(
            status: .buffering,
            qualityDescription: describeQuality(resolvedQuality)
        )
        do {
            try await performLoad(from: remoteURL, quality: resolvedQuality)
        } catch {
            state = PlayerState(status: .failed(error.localizedDescription))
        }
    }

    public func play() {
        player?.play()
    }

    public func pause() {
        player?.pause()
    }

    public func stop() {
        player?.pause()
        player = nil
        didPreparePlayerForCurrentLoad = false
        Task {
            await scheduler.onBufferStateChange(nil)
            await scheduler.onTelemetry(nil)
            await scheduler.stop()
        }
        server.stop()
    }

    public func playlistURL() -> URL? {
        currentRewriteConfiguration?.playlistURL
    }

    public func registerAuxiliaryAsset(
        data: Data,
        identifier: String,
        type: AuxiliaryAssetType
    ) async {
        await auxiliaryStore.register(data: data, identifier: identifier, type: type)
    }

    public func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async {
        self.configuration = configuration
        await applyConfiguration()
    }

    private func performLoad(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy) async throws {
        if server.port == nil {
            try server.start()
        }

        didPreparePlayerForCurrentLoad = false

        let baseURL = try await waitForBaseURL()

        let playlist = try await fetchMediaPlaylist(from: remoteURL, quality: quality)
        currentPlaylist = playlist
        await segmentCatalog.update(with: playlist)

        await scheduler.onBufferStateChange(nil)
        await scheduler.stop()
        await scheduler.enqueueUpcomingPlaylists(configuration.upcomingPlaylists)

        await scheduler.onBufferStateChange { [weak self] bufferState in
            guard let self else { return }
            await self.handleBufferStateChange(bufferState)
        }

        await scheduler.start(playlist: playlist, fetcher: segmentFetcher, cache: cache)
        logger.log("Proxy base URL: \(baseURL.absoluteString)", category: .player)

        let rewriteConfiguration = HLSRewriteConfiguration(
            proxyBaseURL: baseURL,
            hideUntilBuffered: configuration.bufferPolicy.hideUntilBuffered,
            artificialBandwidth: configuration.lowLatencyOptions?.canSkipUntil.map { Int($0 * 1_000_000) },
            qualityPolicy: quality,
            lowLatencyOptions: configuration.lowLatencyOptions
        )
        currentRewriteConfiguration = rewriteConfiguration

        let bufferState = await scheduler.bufferState()
        await updatePlaybackState(with: bufferState)
    }

    private func describeQuality(_ policy: HLSRewriteConfiguration.QualityPolicy) -> String {
        switch policy {
        case .automatic:
            return "auto"
        case .locked(let profile):
            return profile.name
        }
    }

    private func preparePlayer(with url: URL) {
        if let existing = player {
            existing.replaceCurrentItem(with: AVPlayerItem(url: url))
        } else {
            player = AVPlayer(url: url)
        }
    }

    private func fetchMediaPlaylist(from url: URL, quality: HLSRewriteConfiguration.QualityPolicy) async throws -> MediaPlaylist {
        let text = try await fetchManifestText(from: url)
        let manifest = try parser.parse(text, baseURL: url)

        if let playlist = manifest.mediaPlaylist {
            return playlist
        }

        guard let variant = selectVariant(from: manifest.variants, policy: quality) else {
            throw URLError(.badServerResponse)
        }

        return try await fetchMediaPlaylist(from: variant.url, quality: quality)
    }

    private func fetchManifestText(from url: URL) async throws -> String {
        let fetcher = HLSManifestFetcher(
            url: url,
            retryPolicy: configuration.manifestRetryPolicy,
            logger: logger
        )
        return try await fetcher.fetchManifest(from: url, allowInsecure: configuration.allowInsecureManifests)
    }

    private func selectVariant(from variants: [VariantPlaylist], policy: HLSRewriteConfiguration.QualityPolicy) -> VariantPlaylist? {
        switch policy {
        case .automatic:
            return variants.first
        case .locked(let profile):
            return variants.first(where: { profile.matches(bandwidth: $0.attributes.bandwidth) }) ?? variants.first
        }
    }

    private func makeDebugHandler() -> ProxyRouter.Handler {
        { @Sendable [cache, scheduler] _ in
            let metrics = await cache.metrics()
            let bufferState = await scheduler.bufferState()
        let payload: [String: Any] = [
            "buffered_segments": bufferState.readySequences.count,
            "prefetch_depth_seconds": bufferState.prefetchDepthSeconds,
            "played_through_sequence": bufferState.playedThroughSequence ?? NSNull(),
            "cache_hits": metrics.hitCount,
            "cache_misses": metrics.missCount,
            "cached_bytes": metrics.totalBytes,
        ]
            return HTTPResponse.json(payload)
        }
    }

    private func metricsHandler() -> ProxyRouter.Handler {
        MetricsHandler(cache: cache, scheduler: scheduler).makeHandler()
    }

    private func refreshPlaylist(bufferState: BufferState) async {
        guard
            let playlist = currentPlaylist,
            let config = currentRewriteConfiguration
        else { return }

        let playlistText = rewriter.rewrite(mediaPlaylist: playlist, config: config, bufferState: bufferState)
        await playlistStore.update(playlistText)
    }

    private func handleBufferStateChange(_ bufferState: BufferState) async {
        await updatePlaybackState(with: bufferState)
    }

    private func resolveQualityPolicy(
        requested: HLSRewriteConfiguration.QualityPolicy
    ) -> HLSRewriteConfiguration.QualityPolicy {
        switch requested {
        case .automatic:
            return configuration.qualityPolicy
        case .locked:
            return requested
        }
    }

    private static func diskDirectory(for policy: ProxyPlayerConfiguration.CachePolicy) -> URL? {
        guard policy.enableDiskCache else { return nil }
        if let directory = policy.diskDirectory {
            return directory
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSProxyCache", isDirectory: true)
    }

    private func applyConfiguration() async {
        await cache.updateConfiguration(
            capacity: configuration.cachePolicy.memoryCapacity,
            diskDirectory: ProxyHLSPlayer.diskDirectory(for: configuration.cachePolicy)
        )
        await segmentFetcher.updateValidationPolicy(configuration.segmentValidation)
        await scheduler.updateConfiguration(.init(
            targetBufferSeconds: configuration.bufferPolicy.targetBufferSeconds,
            maxSegments: configuration.bufferPolicy.maxPrefetchSegments
        ))
        await scheduler.enqueueUpcomingPlaylists(configuration.upcomingPlaylists)
        await scheduler.onTelemetry(makeTelemetryHandler())
    }

    private func makeTelemetryHandler() -> (@Sendable (SegmentPrefetchScheduler.Telemetry) async -> Void) {
        { [logger] telemetry in
            logger.log(
                "scheduled=\(telemetry.scheduledSequences) ready=\(telemetry.readyCount) failures=\(telemetry.failureCount)",
                category: .scheduler
            )
        }
    }

    private func waitForBaseURL() async throws -> URL {
        for _ in 0..<50 {
            if let url = server.baseURL, server.port != 0 {
                return url
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw URLError(.cannotFindHost)
    }

    private func shouldDelayPlayback(for bufferState: BufferState) -> Bool {
        configuration.bufferPolicy.hideUntilBuffered && bufferState.prefetchDepthSeconds <= 0
    }

    private func updatePlaybackState(with bufferState: BufferState) async {
        guard let rewriteConfiguration = currentRewriteConfiguration else { return }

        if shouldDelayPlayback(for: bufferState) {
            state = PlayerState(
                status: .buffering,
                bufferDepthSeconds: bufferState.prefetchDepthSeconds,
                qualityDescription: state.qualityDescription
            )
            return
        }

        await refreshPlaylist(bufferState: bufferState)

        if !didPreparePlayerForCurrentLoad {
            preparePlayer(with: rewriteConfiguration.playlistURL)
            didPreparePlayerForCurrentLoad = true
        }

        state = PlayerState(
            status: .ready,
            bufferDepthSeconds: bufferState.prefetchDepthSeconds,
            qualityDescription: state.qualityDescription
        )
    }
}
#else
public final class ProxyHLSPlayer {
    public init() {}
    public func load(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy = .automatic) async {}
    public func play() {}
    public func pause() {}
    public func stop() {}
}
#endif
