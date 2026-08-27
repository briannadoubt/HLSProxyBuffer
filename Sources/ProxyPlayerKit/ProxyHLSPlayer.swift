import Foundation
import HLSCore
import LocalProxy
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Observation)
import Observation
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Observation) && canImport(AVFoundation)

public struct AuxiliaryRenditionRegistration: Sendable, Equatable {
    public let kind: HLSManifest.Rendition.Kind
    public let groupId: String
    public let name: String
    public let language: String?
    public let isDefault: Bool
    public let isAutoSelect: Bool
    public let isForced: Bool
    public let characteristics: [String]

    public init(
        kind: HLSManifest.Rendition.Kind,
        groupId: String,
        name: String,
        language: String? = nil,
        isDefault: Bool = false,
        isAutoSelect: Bool = false,
        isForced: Bool = false,
        characteristics: [String] = []
    ) {
        self.kind = kind
        self.groupId = groupId
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.isAutoSelect = isAutoSelect
        self.isForced = isForced
        self.characteristics = characteristics
    }
}

/// Orchestrates the LL-HLS proxy pipeline and exposes observable playback state for UI surfaces.
@Observable
@MainActor
public final class ProxyHLSPlayer {
    public nonisolated static func keyIdentifier(forKeyURI uri: URL) -> String {
        digest(for: uri.absoluteString)
    }

    private nonisolated static func digest(for string: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
        #endif
    }

    private struct ResolvedRenditionInfo: Sendable {
        let rendition: HLSManifest.Rendition
        let remoteURI: URL?
        let namespace: String?
        let playlistIdentifier: String?
        let assetType: AuxiliaryAssetType?

        init(
            rendition: HLSManifest.Rendition,
            remoteURI: URL?,
            namespace: String?,
            playlistIdentifier: String?,
            assetType: AuxiliaryAssetType?
        ) {
            self.rendition = rendition
            self.remoteURI = remoteURI
            self.namespace = namespace
            self.playlistIdentifier = playlistIdentifier
            self.assetType = assetType
        }
    }

    private struct AuxiliaryRegistration: Sendable {
        let identifier: String
        let type: AuxiliaryAssetType
        let descriptor: AuxiliaryRenditionRegistration?
        let duration: TimeInterval
    }

    private struct ResolvedRenditionReport: Sendable {
        let remoteURL: URL
        let localURL: URL
        let namespace: String
        let playlistIdentifier: String
    }

    private enum PlaylistPaths {
        static let variant = "variants/main.m3u8"
    }

    public private(set) var player: AVPlayer?
    public private(set) var status: PlayerState.Status = .idle
    public private(set) var bufferDepthSeconds: TimeInterval = 0
    public private(set) var qualityDescription = "auto"
    public var state: PlayerState {
        PlayerState(
            status: status,
            bufferDepthSeconds: bufferDepthSeconds,
            qualityDescription: qualityDescription
        )
    }
    public private(set) var configuration: ProxyPlayerConfiguration
    public private(set) var variants: [VariantPlaylist] = []
    public private(set) var audioRenditions: [HLSManifest.Rendition] = []
    public private(set) var subtitleRenditions: [HLSManifest.Rendition] = []
    public private(set) var activeAudioRendition: HLSManifest.Rendition?
    public private(set) var activeSubtitleRendition: HLSManifest.Rendition?

    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let manifestProcessor = ManifestProcessor()
    @ObservationIgnored private let cache: HLSSegmentCache
    @ObservationIgnored private let scheduler: SegmentPrefetchScheduler
    @ObservationIgnored private let playlistRefresher: PlaylistRefreshController
    @ObservationIgnored private let playlistStore = PlaylistStore()
    @ObservationIgnored private let auxiliaryStore = AuxiliaryAssetStore()
    @ObservationIgnored private let router = ProxyRouter()
    @ObservationIgnored private let segmentCatalog = SegmentCatalog()
    @ObservationIgnored private let segmentFetcher: HLSSegmentFetcher
    @ObservationIgnored private var currentPlaylist: MediaPlaylist?
    @ObservationIgnored private var currentRewriteConfiguration: HLSRewriteConfiguration?
    @ObservationIgnored private var didPreparePlayerForCurrentLoad = false
    @ObservationIgnored private lazy var server = ProxyServer(router: router)
    @ObservationIgnored private let diagnostics: ProxyPlayerDiagnostics
    @ObservationIgnored private let throughputEstimator: ThroughputEstimator
    @ObservationIgnored private let adaptiveController: AdaptiveVariantController
    @ObservationIgnored private let cacheDirectoryIdentifier: String
    @ObservationIgnored private var activeVariant: VariantPlaylist?
    @ObservationIgnored private var abrSwitchInProgress = false
    @ObservationIgnored private var latestBufferState: BufferState?
    @ObservationIgnored private var resolvedRenditions: [String: ResolvedRenditionInfo] = [:]
    @ObservationIgnored private var orderedRenditionInfos: [ResolvedRenditionInfo] = []
    @ObservationIgnored private var renditionPlaylists: [String: MediaPlaylist] = [:]
    @ObservationIgnored private var resolvedRenditionReports: [ResolvedRenditionReport] = []
    @ObservationIgnored private var resolvedSupplementalPlaylists: [ResolvedRenditionReport] = []
    @ObservationIgnored private var auxiliaryRegistrations: [AuxiliaryRegistration] = []
    @ObservationIgnored private var latestManifestRenditions: [HLSManifest.Rendition] = []
    @ObservationIgnored private var masterProtocolVersion: Int?
    @ObservationIgnored private var masterIndependentSegments = false
    @ObservationIgnored private var masterPassthroughTags: [String] = []
    @ObservationIgnored private var masterSessionKeys: [HLSKey] = []
    @ObservationIgnored private var latestKeyStatuses: [ProxyPlayerDiagnostics.KeyStatus] = []
    @ObservationIgnored private var shouldPlayWhenReady = false
    @ObservationIgnored private var mediaSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var initializationTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadTask: Task<Void, Error>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var renditionRefreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var stateContinuations: [UUID: AsyncStream<PlayerState>.Continuation] = [:]
    @ObservationIgnored private var playbackTimeObserver: Any?
    @ObservationIgnored private var playbackTimeline: [(sequence: Int, endTime: TimeInterval)] = []
    @ObservationIgnored private var lastPlaybackSequence: Int?

    public init(
        configuration: ProxyPlayerConfiguration = .init(),
        logger: Logger = ProxyPlayerLogger(),
        diagnostics: ProxyPlayerDiagnostics = .init()
    ) {
        self.configuration = configuration
        let cacheDirectoryIdentifier = UUID().uuidString
        self.cacheDirectoryIdentifier = cacheDirectoryIdentifier
        self.logger = logger
        self.diagnostics = diagnostics
        self.throughputEstimator = ThroughputEstimator(configuration: .init(window: configuration.abrPolicy.estimatorWindow))
        self.adaptiveController = AdaptiveVariantController(policy: Self.abrPolicy(from: configuration), logger: logger)
        self.segmentFetcher = HLSSegmentFetcher(validationPolicy: configuration.segmentValidation)
        self.cache = HLSSegmentCache(
            capacityBytes: configuration.cachePolicy.memoryCapacityBytes,
            diskDirectory: ProxyHLSPlayer.diskDirectory(
                for: configuration.cachePolicy,
                identifier: cacheDirectoryIdentifier
            ),
            diskCapacityBytes: configuration.cachePolicy.diskCapacityBytes
        )
        self.scheduler = SegmentPrefetchScheduler(configuration: .init(
            targetBufferSeconds: configuration.bufferPolicy.targetBufferSeconds,
            maxSegments: configuration.bufferPolicy.maxPrefetchSegments,
            targetPartCount: configuration.lowLatencyPolicy.isEnabled ? configuration.lowLatencyPolicy.targetPartBufferCount : 0
        ))
        self.playlistRefresher = PlaylistRefreshController(
            configuration: .init(
                refreshInterval: configuration.bufferPolicy.refreshInterval,
                maxBackoffInterval: configuration.bufferPolicy.maxRefreshBackoff
            ),
            logger: logger
        )

        let masterHandler = PlaylistHandler(store: playlistStore, identifier: PlaylistStore.Identifier.master)
        router.register(path: "/playlist.m3u8", handler: masterHandler.makeHandler())

        let variantHandler = PlaylistHandler(
            store: playlistStore,
            identifier: PlaylistStore.Identifier.primaryVariant,
            onServe: diagnostics.onPlaylistServed
        )
        router.register(path: "/\(PlaylistPaths.variant)", handler: variantHandler.makeHandler())

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
        let renditionHandler = RenditionPlaylistHandler(store: playlistStore)
        router.register(path: "/renditions/*", handler: renditionHandler.makeHandler())

        router.register(path: "/debug/status", handler: makeDebugHandler())
        router.register(path: "/metrics", handler: metricsHandler())

        initializationTask = Task {
            await segmentFetcher.onMetrics(makeSegmentMetricsHandler())
            await applyConfiguration()
        }
    }

    /// Ordered player-state changes with bounded buffering for non-SwiftUI consumers.
    public func stateUpdates() -> AsyncStream<PlayerState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stateContinuations.removeValue(forKey: id) }
            }
        }
    }

    public func load(
        from remoteURL: URL,
        quality: HLSRewriteConfiguration.QualityPolicy = .automatic
    ) async {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        activeLoadTask?.cancel()
        if let activeLoadTask { _ = await activeLoadTask.result }
        if let cleanupTask { await cleanupTask.value }
        guard generation == sessionGeneration else { return }
        if let initializationTask {
            await initializationTask.value
            self.initializationTask = nil
        }
        let resolvedQuality = resolveQualityPolicy(requested: quality)
        updateState(PlayerState(
            status: .buffering,
            qualityDescription: describeQuality(resolvedQuality)
        ))
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performLoad(
                from: remoteURL,
                quality: resolvedQuality,
                generation: generation
            )
        }
        activeLoadTask = task
        do {
            try await task.value
            if generation == sessionGeneration { activeLoadTask = nil }
        } catch is CancellationError {
            if generation == sessionGeneration {
                activeLoadTask = nil
                updateState(PlayerState())
            }
        } catch {
            if generation == sessionGeneration {
                activeLoadTask = nil
                updateState(PlayerState(status: .failed(error.localizedDescription)))
            }
        }
    }

    public func play() {
        shouldPlayWhenReady = true
        player?.play()
    }

    public func pause() {
        shouldPlayWhenReady = false
        player?.pause()
    }

    public func stop() {
        sessionGeneration &+= 1
        let loadTask = activeLoadTask
        loadTask?.cancel()
        activeLoadTask = nil
        cleanupTask?.cancel()
        shouldPlayWhenReady = false
        player?.pause()
        removePlaybackTimeObserver()
        player = nil
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        didPreparePlayerForCurrentLoad = false
        variants = []
        activeVariant = nil
        abrSwitchInProgress = false
        latestBufferState = nil
        for task in renditionRefreshTasks.values { task.cancel() }
        renditionRefreshTasks.removeAll()
        let scheduler = scheduler
        let playlistRefresher = playlistRefresher
        let server = server
        cleanupTask = Task { @MainActor [weak self] in
            if let loadTask { _ = await loadTask.result }
            await scheduler.onBufferStateChange(nil)
            await scheduler.onTelemetry(nil)
            await scheduler.stop()
            await playlistRefresher.stop()
            await self?.clearResolvedRenditions()
            // AVFoundation can finish media-selection requests after the item is
            // released. Keep loopback alive briefly so those reads drain cleanly.
            try? await Task.sleep(nanoseconds: 50_000_000)
            server.stop()
        }
        latestKeyStatuses = []
        updateState(PlayerState())
    }

    /// Stops playback and waits until all session-owned async work has been torn down.
    public func stopAndWait() async {
        stop()
        if let cleanupTask {
            await cleanupTask.value
            self.cleanupTask = nil
        }
    }

    public func playlistURL() -> URL? {
        currentRewriteConfiguration?.playlistURL
    }

    public func selectRendition(kind: HLSManifest.Rendition.Kind, id: String?) {
        if let id, let info = resolvedRenditions[id], info.rendition.type == kind {
            updateActiveRendition(info.rendition, for: kind, notify: true)
        } else {
            updateActiveRendition(nil, for: kind, notify: true)
        }
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.sessionGeneration else { return }
            await self.updateMasterPlaylist()
        }
    }

    public func registerAuxiliaryAsset(
        data: Data,
        identifier: String,
        type: AuxiliaryAssetType,
        rendition: AuxiliaryRenditionRegistration? = nil,
        duration: TimeInterval = 3_600
    ) async {
        await auxiliaryStore.register(data: data, identifier: identifier, type: type)
        if let rendition, rendition.kind.supportedAssetType == nil {
            logger.log("Auxiliary renditions do not support kind \(rendition.kind)", category: .player)
            return
        }
        if let rendition, rendition.kind.supportedAssetType != type {
            logger.log("Rendition kind \(rendition.kind) must use matching asset type.", category: .player)
            return
        }
        auxiliaryRegistrations.append(.init(
            identifier: identifier,
            type: type,
            descriptor: rendition,
            duration: max(0.001, duration)
        ))
    }

    public func updateConfiguration(_ configuration: ProxyPlayerConfiguration) async {
        self.configuration = configuration
        await applyConfiguration()
    }

    private func performLoad(
        from remoteURL: URL,
        quality: HLSRewriteConfiguration.QualityPolicy,
        generation: UInt64
    ) async throws {
        try ensureActiveSession(generation)
        if server.port == nil {
            try server.start()
        }

        didPreparePlayerForCurrentLoad = false
        await clearResolvedRenditions()
        await cache.clear()
        await throughputEstimator.reset()
        await adaptiveController.reset()
        try ensureActiveSession(generation)

        let baseURL = try await waitForBaseURL()

        let playlistResult = try await fetchMediaPlaylist(from: remoteURL, quality: quality)
        try ensureActiveSession(generation)
        variants = playlistResult.variants
        if let variant = playlistResult.selectedVariant {
            activeVariant = variant
            diagnostics.onQualityChanged?(variant)
        } else {
            activeVariant = nil
        }
        let adaptiveVariants = playlistResult.selectedVariant.map {
            abrCompatibleVariants(in: playlistResult.variants, with: $0)
        } ?? playlistResult.variants
        await adaptiveController.updateVariants(adaptiveVariants)
        let playlist = playlistResult.playlist
        masterProtocolVersion = playlistResult.masterProtocolVersion
        masterIndependentSegments = playlistResult.masterIndependentSegments
        masterPassthroughTags = playlistResult.masterPassthroughTags
        masterSessionKeys = playlistResult.masterSessionKeys
        currentPlaylist = playlist
        updateKeyDiagnostics(for: playlist)
        await segmentCatalog.update(with: playlist, namespace: SegmentCatalog.Namespace.primary)

        await scheduler.onBufferStateChange(nil)
        await scheduler.stop()
        await scheduler.enqueueUpcomingPlaylists(configuration.upcomingPlaylists)

        await scheduler.onBufferStateChange { [weak self] bufferState in
            guard let self else { return }
            await self.handleBufferStateChange(bufferState)
        }

        await scheduler.start(playlist: playlist, fetcher: segmentFetcher, cache: cache)
        try ensureActiveSession(generation)
        logger.log("Proxy base URL: \(baseURL.absoluteString)", category: .player)

        let lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions?
        if configuration.lowLatencyPolicy.isEnabled {
            lowLatencyOptions = configuration.lowLatencyOptions
        } else {
            lowLatencyOptions = nil
        }

        let baseRewriteConfiguration = HLSRewriteConfiguration(
            proxyBaseURL: baseURL,
            hideUntilBuffered: configuration.bufferPolicy.hideUntilBuffered,
            qualityPolicy: quality,
            lowLatencyOptions: lowLatencyOptions,
            keyURLResolver: keyURLResolver(for: baseURL)
        )
        masterPassthroughTags = await resolveMasterPassthroughTags(
            playlistResult.masterPassthroughTags,
            sourceURL: playlistResult.masterURL,
            baseURL: baseURL,
            config: baseRewriteConfiguration
        )
        let reportURLMap = await loadRenditionReports(
            playlist.renditionReports,
            baseURL: baseURL,
            config: baseRewriteConfiguration
        )
        let rewriteConfiguration = HLSRewriteConfiguration(
            proxyBaseURL: baseURL,
            hideUntilBuffered: configuration.bufferPolicy.hideUntilBuffered,
            qualityPolicy: quality,
            lowLatencyOptions: lowLatencyOptions,
            keyURLResolver: keyURLResolver(for: baseURL),
            renditionReportURLResolver: { report in reportURLMap[report.uri] }
        )
        currentRewriteConfiguration = rewriteConfiguration

        if configuration.lowLatencyPolicy.isEnabled {
            logger.log(
                "LL-HLS enabled (parts target=\(configuration.lowLatencyPolicy.targetPartBufferCount), blocking=\(configuration.lowLatencyPolicy.enableBlockingReloads))",
                category: .player
            )
        }

        let bufferState = await scheduler.bufferState()
        latestBufferState = bufferState
        latestManifestRenditions = playlistResult.renditions
        await resolveRenditions(playlistResult.renditions, baseURL: baseURL)
        updateRenditionSelections(for: activeVariant)
        await loadRenditionPlaylists(config: rewriteConfiguration)
        try ensureActiveSession(generation)
        await updateMasterPlaylist()
        await updatePlaybackState(with: bufferState)
        await startPlaylistRefresh(at: playlistResult.url, generation: generation)
        startRenditionRefresh(generation: generation, config: rewriteConfiguration)
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
        removePlaybackTimeObserver()
        rebuildPlaybackTimeline()
        if let existing = player {
            existing.replaceCurrentItem(with: AVPlayerItem(url: url))
        } else {
            player = AVPlayer(url: url)
        }
        installPlaybackTimeObserver()
        applyActiveRenditionsToPlayer()
        if shouldPlayWhenReady {
            player?.play()
        }
    }

    private func rebuildPlaybackTimeline() {
        var elapsed: TimeInterval = 0
        playbackTimeline = (currentPlaylist?.segments ?? []).map { segment in
            elapsed += segment.duration
            return (segment.sequence, elapsed)
        }
        lastPlaybackSequence = nil
    }

    private func extendPlaybackTimeline(with playlist: MediaPlaylist) {
        guard !playbackTimeline.isEmpty else {
            rebuildPlaybackTimeline()
            return
        }
        let lastSequence = playbackTimeline.last?.sequence ?? Int.min
        var elapsed = playbackTimeline.last?.endTime ?? 0
        for segment in playlist.segments where segment.sequence > lastSequence {
            elapsed += segment.duration
            playbackTimeline.append((segment.sequence, elapsed))
        }
    }

    private func resetPlaybackTimeline(with playlist: MediaPlaylist) {
        let currentTime = player?.currentTime().seconds ?? 0
        var elapsed = currentTime.isFinite ? currentTime : 0
        playbackTimeline = playlist.segments.map { segment in
            elapsed += segment.duration
            return (segment.sequence, elapsed)
        }
        lastPlaybackSequence = nil
    }

    private func installPlaybackTimeObserver() {
        guard let player else { return }
        let generation = sessionGeneration
        playbackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.sessionGeneration else { return }
                await self.consumePlayedSegments(through: seconds)
            }
        }
    }

    private func removePlaybackTimeObserver() {
        guard let playbackTimeObserver else { return }
        player?.removeTimeObserver(playbackTimeObserver)
        self.playbackTimeObserver = nil
        playbackTimeline.removeAll()
        lastPlaybackSequence = nil
    }

    private func consumePlayedSegments(through seconds: TimeInterval) async {
        let played = playbackTimeline.last(where: { $0.endTime <= seconds })?.sequence
        guard let played, played != lastPlaybackSequence else { return }
        lastPlaybackSequence = played
        await scheduler.consume(sequence: played)
    }

    private func fetchMediaPlaylist(
        from url: URL,
        quality: HLSRewriteConfiguration.QualityPolicy
    ) async throws -> (
        playlist: MediaPlaylist,
        url: URL,
        variants: [VariantPlaylist],
        renditions: [HLSManifest.Rendition],
        selectedVariant: VariantPlaylist?,
        masterProtocolVersion: Int?,
        masterIndependentSegments: Bool,
        masterPassthroughTags: [String],
        masterSessionKeys: [HLSKey],
        masterURL: URL?
    ) {
        let text = try await fetchManifestText(from: url)
        let manifest = try await manifestProcessor.parse(text, baseURL: url)

        if let playlist = manifest.mediaPlaylist {
            return (
                playlist,
                url,
                manifest.variants,
                manifest.renditions,
                nil,
                manifest.protocolVersion,
                manifest.independentSegments,
                manifest.passthroughTags,
                manifest.sessionKeys,
                nil
            )
        }

        guard let variant = selectVariant(from: manifest.variants, policy: quality) else {
            throw URLError(.badServerResponse)
        }

        let result = try await fetchMediaPlaylist(from: variant.url, quality: quality)
        if manifest.variants.isEmpty {
            return result
        }
        let selectedVariant = result.selectedVariant ?? variant
        let renditions = manifest.renditions.isEmpty ? result.renditions : manifest.renditions
        return (
            result.playlist,
            result.url,
            manifest.variants,
            renditions,
            selectedVariant,
            manifest.protocolVersion,
            manifest.independentSegments,
            manifest.passthroughTags,
            manifest.sessionKeys,
            url
        )
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
            return variants.min {
                ($0.attributes.averageBandwidth ?? $0.attributes.bandwidth ?? Int.max)
                    < ($1.attributes.averageBandwidth ?? $1.attributes.bandwidth ?? Int.max)
            }
        case .locked(let profile):
            return variants.first(where: { profile.matches(bandwidth: $0.attributes.bandwidth) }) ?? variants.first
        }
    }

    /// Restrict automatic switching to variants whose rendition groups and codec
    /// families match the selected stream. Crossing these boundaries can silently
    /// change languages, captions, or decoder requirements mid-playback.
    private func abrCompatibleVariants(
        in variants: [VariantPlaylist],
        with selected: VariantPlaylist
    ) -> [VariantPlaylist] {
        let selectedAttributes = selected.attributes
        let compatible = variants.filter { candidate in
            let attributes = candidate.attributes
            return attributes.audioGroupId == selectedAttributes.audioGroupId
                && attributes.subtitleGroupId == selectedAttributes.subtitleGroupId
                && attributes.closedCaptionGroupId == selectedAttributes.closedCaptionGroupId
                && codecFamilies(attributes.codecs) == codecFamilies(selectedAttributes.codecs)
        }
        return compatible.isEmpty ? [selected] : compatible
    }

    private func codecFamilies(_ codecs: String?) -> Set<String>? {
        codecs.map { value in
            Set(value.split(separator: ",").map { codec in
                String(codec.trimmingCharacters(in: .whitespaces).prefix(4)).lowercased()
            })
        }
    }

    private func makeDebugHandler() -> ProxyRouter.Handler {
        { @Sendable [weak self, cache, scheduler, playlistRefresher, throughputEstimator, adaptiveController] _ in
            async let metricsTask = cache.metrics()
            async let bufferTask = scheduler.bufferState()
            async let refreshTask = playlistRefresher.metrics()
            async let throughputTask = throughputEstimator.sample()
            async let decisionTask = adaptiveController.latestDecision()
            let (metrics, bufferState, refresh, throughput, decision) = await (
                metricsTask,
                bufferTask,
                refreshTask,
                throughputTask,
                decisionTask
            )

            let variantMetadata = await MainActor.run { [weak self] () -> (String?, Int?) in
                guard let player = self, let variant = player.activeVariant else {
                    return (nil, nil)
                }
                let bitrate = variant.attributes.averageBandwidth ?? variant.attributes.bandwidth
                return (variant.url.absoluteString, bitrate)
            }

            let partHoldBack = await MainActor.run { [weak self] () -> Double? in
                guard let playlist = self?.currentPlaylist else { return nil }
                return playlist.serverControl?.partHoldBack
            }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let refreshDate: Any = {
                if let date = refresh.lastRefreshDate {
                    return dateFormatter.string(from: date)
                }
                return NSNull()
            }()

            let refreshError: Any = refresh.lastErrorDescription ?? NSNull()
            let remoteSequence: Any = refresh.remoteMediaSequence ?? NSNull()

            let renditionMetadata = await MainActor.run { [weak self] () -> (String?, String?) in
                guard let player = self else { return (nil, nil) }
                return (player.activeAudioRendition?.name, player.activeSubtitleRendition?.name)
            }

            let keyStatuses = await MainActor.run { [weak self] () -> [ProxyPlayerDiagnostics.KeyStatus] in
                guard let player = self else { return [] }
                return player.latestKeyStatuses
            }
            let keyMetadata = keyStatuses.map {
                [
                    "method": $0.method.rawValue,
                    "uri_hash": $0.uriHash,
                    "is_session": $0.isSessionKey
                ]
            }

            let lowLatencyEnabled = await MainActor.run { [weak self] () -> Bool in
                self?.configuration.lowLatencyPolicy.isEnabled ?? false
            }

            let payload: [String: Any] = [
                "buffered_segments": bufferState.readySequences.count,
                "prefetch_depth_seconds": bufferState.prefetchDepthSeconds,
                "part_prefetch_depth_seconds": bufferState.partPrefetchDepthSeconds,
                "played_through_sequence": bufferState.playedThroughSequence ?? NSNull(),
                "ready_part_sequences": Dictionary(uniqueKeysWithValues: bufferState.readyPartCounts.map { ("\($0.key)", $0.value) }),
                "cache_hits": metrics.hitCount,
                "cache_misses": metrics.missCount,
                "cached_bytes": metrics.totalBytes,
                "last_playlist_refresh": refreshDate,
                "playlist_refresh_failures": refresh.consecutiveFailures,
                "playlist_refresh_error": refreshError,
                "remote_media_sequence": remoteSequence,
                "blocking_reload_active": refresh.blockingReloadEngaged,
                "active_variant_name": variantMetadata.0 ?? NSNull(),
                "variant_bitrate": variantMetadata.1 ?? NSNull(),
                "throughput_bps": throughput?.bitsPerSecond ?? NSNull(),
                "abr_last_reason": decision.map { String(describing: $0.reason) } ?? NSNull(),
                "active_audio_rendition": renditionMetadata.0 ?? NSNull(),
                "active_subtitle_rendition": renditionMetadata.1 ?? NSNull(),
                "keys": keyMetadata,
                "part_hold_back_seconds": partHoldBack ?? NSNull(),
                "low_latency_mode": lowLatencyEnabled
            ]
            return HTTPResponse.json(payload)
        }
    }

    private func clearResolvedRenditions() async {
        for info in orderedRenditionInfos {
            if let namespace = info.namespace {
                await segmentCatalog.removeEntries(for: namespace)
            }
        }
        for report in resolvedRenditionReports {
            await segmentCatalog.removeEntries(for: report.namespace)
            await playlistStore.remove(report.playlistIdentifier)
        }
        for playlist in resolvedSupplementalPlaylists {
            await segmentCatalog.removeEntries(for: playlist.namespace)
            await playlistStore.remove(playlist.playlistIdentifier)
        }
        resolvedRenditionReports.removeAll()
        resolvedSupplementalPlaylists.removeAll()
        orderedRenditionInfos.removeAll()
        resolvedRenditions.removeAll()
        renditionPlaylists.removeAll()
        audioRenditions = []
        subtitleRenditions = []
        activeAudioRendition = nil
        activeSubtitleRendition = nil
        latestManifestRenditions = []
        masterProtocolVersion = nil
        masterIndependentSegments = false
        masterPassthroughTags = []
        masterSessionKeys = []
    }

    private func resolveRenditions(_ manifestRenditions: [HLSManifest.Rendition], baseURL: URL) async {
        var ordered: [ResolvedRenditionInfo] = []
        var lookup: [String: ResolvedRenditionInfo] = [:]

        func append(_ info: ResolvedRenditionInfo) {
            ordered.append(info)
            lookup[info.rendition.id] = info
        }

        for rendition in manifestRenditions {
            let namespace: String?
            let playlistIdentifier: String?
            let localURL: URL?
            if rendition.uri != nil {
                let ns = renditionNamespace(for: rendition)
                namespace = ns
                playlistIdentifier = PlaylistStore.Identifier.rendition(ns)
                localURL = baseURL
                    .appendingPathComponent("renditions")
                    .appendingPathComponent("\(ns).m3u8")
            } else {
                namespace = nil
                playlistIdentifier = nil
                localURL = nil
            }
            let localized = HLSManifest.Rendition(
                type: rendition.type,
                groupId: rendition.groupId,
                name: rendition.name,
                language: rendition.language,
                isDefault: rendition.isDefault,
                isAutoSelect: rendition.isAutoSelect,
                isForced: rendition.isForced,
                characteristics: rendition.characteristics,
                uri: localURL ?? rendition.uri,
                instreamId: rendition.instreamId,
                additionalAttributes: rendition.additionalAttributes
            )
            append(ResolvedRenditionInfo(
                rendition: localized,
                remoteURI: rendition.uri,
                namespace: namespace,
                playlistIdentifier: playlistIdentifier,
                assetType: nil
            ))
        }

        for registration in auxiliaryRegistrations {
            guard
                let descriptor = registration.descriptor,
                let supportedType = descriptor.kind.supportedAssetType,
                supportedType == registration.type
            else { continue }
            let assetURL = baseURL
                .appendingPathComponent("assets")
                .appendingPathComponent(registration.type.rawValue)
                .appendingPathComponent(registration.identifier)
            let namespace = "aux-\(registration.identifier)"
            let playlistIdentifier = PlaylistStore.Identifier.rendition(namespace)
            let playlistURL = baseURL
                .appendingPathComponent("renditions")
                .appendingPathComponent("\(namespace).m3u8")
            let targetDuration = Int(ceil(registration.duration))
            let playlist = [
                "#EXTM3U",
                "#EXT-X-VERSION:3",
                "#EXT-X-TARGETDURATION:\(targetDuration)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXTINF:\(String(format: "%.3f", registration.duration)),",
                assetURL.absoluteString,
                "#EXT-X-ENDLIST"
            ].joined(separator: "\n")
            await playlistStore.update(playlist, for: playlistIdentifier)
            let rendition = HLSManifest.Rendition(
                type: descriptor.kind,
                groupId: descriptor.groupId,
                name: descriptor.name,
                language: descriptor.language,
                isDefault: descriptor.isDefault,
                isAutoSelect: descriptor.isAutoSelect,
                isForced: descriptor.isForced,
                characteristics: descriptor.characteristics,
                uri: playlistURL
            )
            append(ResolvedRenditionInfo(
                rendition: rendition,
                remoteURI: nil,
                namespace: nil,
                playlistIdentifier: playlistIdentifier,
                assetType: registration.type
            ))
        }

        orderedRenditionInfos = ordered
        resolvedRenditions = lookup
        audioRenditions = ordered.filter { $0.rendition.type == .audio }.map(\.rendition)
        subtitleRenditions = ordered.filter { $0.rendition.type == .subtitles }.map(\.rendition)
    }

    private func loadRenditionPlaylists(config: HLSRewriteConfiguration) async {
        let remoteInfos = orderedRenditionInfos.filter { $0.remoteURI != nil }
        let retryPolicy = configuration.manifestRetryPolicy
        let allowInsecure = configuration.allowInsecureManifests
        let logger = logger
        let results = await withTaskGroup(
            of: (ResolvedRenditionInfo, MediaPlaylist?).self,
            returning: [(ResolvedRenditionInfo, MediaPlaylist?)].self
        ) { group in
            for info in remoteInfos {
                group.addTask {
                    guard let remoteURL = info.remoteURI else { return (info, nil) }
                    do {
                        let fetcher = HLSManifestFetcher(
                            url: remoteURL,
                            retryPolicy: retryPolicy,
                            logger: logger
                        )
                        let text = try await fetcher.fetchManifest(
                            from: remoteURL,
                            allowInsecure: allowInsecure
                        )
                        let manifest = try HLSParser(logger: logger).parse(text, baseURL: remoteURL)
                        return (info, manifest.mediaPlaylist)
                    } catch {
                        logger.log("Failed to load rendition \(info.rendition.name): \(error)", category: .player)
                        return (info, nil)
                    }
                }
            }
            var values: [(ResolvedRenditionInfo, MediaPlaylist?)] = []
            for await result in group { values.append(result) }
            return values
        }
        var successfulIDs: Set<String> = []
        for (info, playlist) in results {
            guard let playlist,
                  let namespace = info.namespace,
                  let playlistIdentifier = info.playlistIdentifier else { continue }
            await segmentCatalog.update(with: playlist, namespace: namespace)
            let rewritten = await manifestProcessor.rewrite(
                mediaPlaylist: playlist,
                config: config,
                bufferState: BufferState(),
                namespace: namespace
            )
            await playlistStore.update(rewritten, for: playlistIdentifier)
            renditionPlaylists[info.rendition.id] = playlist
            successfulIDs.insert(info.rendition.id)
        }
        if successfulIDs.count != remoteInfos.count {
            let failedIDs = Set(remoteInfos.map { $0.rendition.id }).subtracting(successfulIDs)
            orderedRenditionInfos.removeAll { failedIDs.contains($0.rendition.id) }
            for id in failedIDs { resolvedRenditions.removeValue(forKey: id) }
            audioRenditions = orderedRenditionInfos.filter { $0.rendition.type == .audio }.map(\.rendition)
            subtitleRenditions = orderedRenditionInfos.filter { $0.rendition.type == .subtitles }.map(\.rendition)
        }
    }

    private func loadRenditionReports(
        _ reports: [HLSRenditionReport],
        baseURL: URL,
        config: HLSRewriteConfiguration
    ) async -> [URL: URL] {
        var mapping: [URL: URL] = [:]
        var resolved: [ResolvedRenditionReport] = []
        for report in reports {
            let identifier = "report-\(Self.digest(for: report.uri.absoluteString))"
            let info = ResolvedRenditionReport(
                remoteURL: report.uri,
                localURL: baseURL.appendingPathComponent("renditions").appendingPathComponent("\(identifier).m3u8"),
                namespace: identifier,
                playlistIdentifier: PlaylistStore.Identifier.rendition(identifier)
            )
            if await fetchRenditionReport(info, config: config) {
                mapping[report.uri] = info.localURL
                resolved.append(info)
            }
        }
        resolvedRenditionReports = resolved
        return mapping
    }

    private func resolveMasterPassthroughTags(
        _ tags: [String],
        sourceURL: URL?,
        baseURL: URL,
        config: HLSRewriteConfiguration
    ) async -> [String] {
        guard let sourceURL else { return tags }
        var resolvedTags: [String] = []
        var supplementalPlaylists: [ResolvedRenditionReport] = []

        for tag in tags {
            // The public master is flattened to one localhost variant, so pathway
            // steering is neither useful nor safe to forward to the origin.
            if tag.hasPrefix("#EXT-X-CONTENT-STEERING:") {
                logger.log("Removed content steering from flattened proxy master.", category: .rewriter)
                continue
            }
            guard let uriAttribute = quotedAttribute(named: "URI", in: tag),
                  let remoteURL = URL(string: uriAttribute.value, relativeTo: sourceURL)?.absoluteURL else {
                resolvedTags.append(tag)
                continue
            }
            guard configuration.allowInsecureManifests || remoteURL.scheme?.lowercased() == "https" else {
                logger.log("Removed insecure URI-bearing master tag.", category: .rewriter)
                continue
            }

            let identifier = "master-resource-\(Self.digest(for: remoteURL.absoluteString))"
            let localURL: URL
            if tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                || tag.hasPrefix("#EXT-X-IMAGE-STREAM-INF:") {
                let info = ResolvedRenditionReport(
                    remoteURL: remoteURL,
                    localURL: baseURL.appendingPathComponent("renditions").appendingPathComponent("\(identifier).m3u8"),
                    namespace: identifier,
                    playlistIdentifier: PlaylistStore.Identifier.rendition(identifier)
                )
                guard await fetchRenditionReport(info, config: config) else { continue }
                supplementalPlaylists.append(info)
                localURL = info.localURL
            } else {
                do {
                    let data = try await fetchBoundedAuxiliaryData(from: remoteURL)
                    await auxiliaryStore.register(data: data, identifier: identifier, type: .metadata)
                    localURL = baseURL
                        .appendingPathComponent("assets")
                        .appendingPathComponent(AuxiliaryAssetType.metadata.rawValue)
                        .appendingPathComponent(identifier)
                } catch {
                    logger.log("Removed unresolved URI-bearing master tag: \(error)", category: .rewriter)
                    continue
                }
            }
            var rewritten = tag
            rewritten.replaceSubrange(uriAttribute.range, with: localURL.absoluteString)
            resolvedTags.append(rewritten)
        }
        resolvedSupplementalPlaylists = supplementalPlaylists
        return resolvedTags
    }

    private func quotedAttribute(
        named name: String,
        in tag: String
    ) -> (value: String, range: Range<String.Index>)? {
        let prefix = "\(name)=\""
        guard let prefixRange = tag.range(of: prefix) else { return nil }
        let valueStart = prefixRange.upperBound
        guard let valueEnd = tag[valueStart...].firstIndex(of: "\"") else { return nil }
        return (String(tag[valueStart..<valueEnd]), valueStart..<valueEnd)
    }

    private func fetchBoundedAuxiliaryData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return data
    }

    @discardableResult
    private func fetchRenditionReport(
        _ info: ResolvedRenditionReport,
        config: HLSRewriteConfiguration
    ) async -> Bool {
        do {
            let text = try await fetchManifestText(from: info.remoteURL)
            let manifest = try await manifestProcessor.parse(text, baseURL: info.remoteURL)
            guard let playlist = manifest.mediaPlaylist else { return false }
            await segmentCatalog.update(with: playlist, namespace: info.namespace)
            let rewritten = await manifestProcessor.rewrite(
                mediaPlaylist: playlist,
                config: config,
                bufferState: BufferState(),
                namespace: info.namespace
            )
            await playlistStore.update(rewritten, for: info.playlistIdentifier)
            return true
        } catch {
            logger.log("Failed to resolve rendition report: \(error)", category: .player)
            return false
        }
    }

    @discardableResult
    private func fetchRenditionPlaylist(info: ResolvedRenditionInfo, config: HLSRewriteConfiguration) async -> Bool {
        guard
            let remoteURL = info.remoteURI,
            let namespace = info.namespace,
            let playlistIdentifier = info.playlistIdentifier
        else { return false }
        do {
            let text = try await fetchManifestText(from: remoteURL)
            let manifest = try await manifestProcessor.parse(text, baseURL: remoteURL)
            guard let playlist = manifest.mediaPlaylist else {
                logger.log("Rendition playlist missing media body for \(info.rendition.name)", category: .player)
                return false
            }
            await segmentCatalog.update(with: playlist, namespace: namespace)
            let rewritten = await manifestProcessor.rewrite(
                mediaPlaylist: playlist,
                config: config,
                bufferState: BufferState(),
                namespace: namespace
            )
            await playlistStore.update(rewritten, for: playlistIdentifier)
            renditionPlaylists[info.rendition.id] = playlist
            return true
        } catch {
            logger.log("Failed to load rendition \(info.rendition.name): \(error)", category: .player)
            return false
        }
    }

    private func startRenditionRefresh(
        generation: UInt64,
        config: HLSRewriteConfiguration
    ) {
        for task in renditionRefreshTasks.values { task.cancel() }
        renditionRefreshTasks.removeAll()
        for info in orderedRenditionInfos where info.remoteURI != nil {
            let interval = max(
                0.5,
                min(renditionPlaylists[info.rendition.id]?.targetDuration ?? configuration.bufferPolicy.refreshInterval,
                    configuration.bufferPolicy.refreshInterval)
            )
            renditionRefreshTasks[info.rendition.id] = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard let self, generation == self.sessionGeneration else { return }
                    _ = await self.fetchRenditionPlaylist(info: info, config: config)
                }
            }
        }
        for report in resolvedRenditionReports + resolvedSupplementalPlaylists {
            renditionRefreshTasks[report.playlistIdentifier] = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0.5, self?.configuration.bufferPolicy.refreshInterval ?? 2) * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard let self, generation == self.sessionGeneration else { return }
                    _ = await self.fetchRenditionReport(report, config: config)
                }
            }
        }
    }

    private func updateMasterPlaylist() async {
        guard let config = currentRewriteConfiguration else { return }
        let variantURL = config.proxyBaseURL.appendingPathComponent(PlaylistPaths.variant)
        let text = buildMasterPlaylist(variantURL: variantURL)
        await playlistStore.update(text, for: PlaylistStore.Identifier.master)
    }

    private func buildMasterPlaylist(variantURL: URL) -> String {
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(max(masterProtocolVersion ?? 7, 7))"
        ]
        if masterIndependentSegments {
            lines.append("#EXT-X-INDEPENDENT-SEGMENTS")
        }
        lines.append(contentsOf: masterPassthroughTags)
        if let baseURL = currentRewriteConfiguration?.proxyBaseURL {
            let resolver = keyURLResolver(for: baseURL)
            for key in masterSessionKeys {
                var attributes = ["METHOD=\(key.method.rawValue)"]
                if let uri = resolver?(key) ?? key.uri {
                    attributes.append("URI=\"\(uri.absoluteString)\"")
                }
                if let keyFormat = key.keyFormat {
                    attributes.append("KEYFORMAT=\"\(keyFormat)\"")
                }
                if !key.keyFormatVersions.isEmpty {
                    attributes.append("KEYFORMATVERSIONS=\"\(key.keyFormatVersions.joined(separator: "/"))\"")
                }
                lines.append("#EXT-X-SESSION-KEY:\(attributes.joined(separator: ","))")
            }
        }
        var defaultRenditionIDs: [String: String] = [:]
        for info in orderedRenditionInfos {
            let key = "\(info.rendition.type.rawValue):\(info.rendition.groupId)"
            if isActive(rendition: info.rendition) {
                defaultRenditionIDs[key] = info.rendition.id
            } else if defaultRenditionIDs[key] == nil, info.rendition.isDefault {
                defaultRenditionIDs[key] = info.rendition.id
            }
        }
        for info in orderedRenditionInfos {
            var attributes: [String] = []
            attributes.append("TYPE=\(info.rendition.type.attributeValue)")
            attributes.append("GROUP-ID=\"\(info.rendition.groupId)\"")
            attributes.append("NAME=\"\(info.rendition.name)\"")
            if let language = info.rendition.language {
                attributes.append("LANGUAGE=\"\(language)\"")
            }
            let defaultKey = "\(info.rendition.type.rawValue):\(info.rendition.groupId)"
            attributes.append("DEFAULT=\(defaultRenditionIDs[defaultKey] == info.rendition.id ? "YES" : "NO")")
            attributes.append("AUTOSELECT=\(info.rendition.isAutoSelect ? "YES" : "NO")")
            attributes.append("FORCED=\(info.rendition.isForced ? "YES" : "NO")")
            if !info.rendition.characteristics.isEmpty {
                let joined = info.rendition.characteristics.joined(separator: ",")
                attributes.append("CHARACTERISTICS=\"\(joined)\"")
            }
            if let instreamId = info.rendition.instreamId {
                attributes.append("INSTREAM-ID=\"\(instreamId)\"")
            }
            if let uri = info.rendition.uri {
                attributes.append("URI=\"\(uri.absoluteString)\"")
            }
            for (key, value) in info.rendition.additionalAttributes.sorted(by: { $0.key < $1.key }) {
                attributes.append("\(key)=\"\(value)\"")
            }
            lines.append("#EXT-X-MEDIA:\(attributes.joined(separator: ","))")
        }

        lines.append("#EXT-X-STREAM-INF:\(streamAttributes(for: activeVariant))")
        lines.append(variantURL.absoluteString)
        return lines.joined(separator: "\n")
    }

    private func streamAttributes(for variant: VariantPlaylist?) -> String {
        var attributes: [String] = []
        let data = variant?.attributes
        attributes.append("BANDWIDTH=\(data?.bandwidth ?? 0)")
        if let average = data?.averageBandwidth {
            attributes.append("AVERAGE-BANDWIDTH=\(average)")
        }
        if let frameRate = data?.frameRate {
            attributes.append(String(format: "FRAME-RATE=%.2f", frameRate))
        }
        if let resolution = data?.resolution {
            attributes.append("RESOLUTION=\(resolution.width)x\(resolution.height)")
        }
        if let codecs = data?.codecs {
            attributes.append("CODECS=\"\(codecs)\"")
        }
        if let audioGroup = data?.audioGroupId {
            attributes.append("AUDIO=\"\(audioGroup)\"")
        }
        if let subtitleGroup = data?.subtitleGroupId {
            attributes.append("SUBTITLES=\"\(subtitleGroup)\"")
        }
        if let captions = data?.closedCaptionGroupId {
            attributes.append("CLOSED-CAPTIONS=\"\(captions)\"")
        }
        for (key, value) in data?.additionalAttributes.sorted(by: { $0.key < $1.key }) ?? [] {
            switch key {
            case "VIDEO-RANGE", "HDCP-LEVEL", "SCORE":
                attributes.append("\(key)=\(value)")
            default:
                attributes.append("\(key)=\"\(value)\"")
            }
        }
        return attributes.joined(separator: ",")
    }

    private func renditionNamespace(for rendition: HLSManifest.Rendition) -> String {
        rendition.id
    }

    private func isActive(rendition: HLSManifest.Rendition) -> Bool {
        switch rendition.type {
        case .audio:
            return activeAudioRendition?.id == rendition.id
        case .subtitles:
            return activeSubtitleRendition?.id == rendition.id
        case .closedCaptions:
            return false
        }
    }

    private func updateRenditionSelections(for variant: VariantPlaylist?) {
        let audio = defaultRendition(for: .audio, variant: variant)
        let subtitles = defaultRendition(for: .subtitles, variant: variant)
        updateActiveRendition(audio, for: .audio, notify: false)
        updateActiveRendition(subtitles, for: .subtitles, notify: false)
    }

    private func defaultRendition(for kind: HLSManifest.Rendition.Kind, variant: VariantPlaylist?) -> HLSManifest.Rendition? {
        let groupId: String?
        switch kind {
        case .audio:
            groupId = variant?.attributes.audioGroupId
        case .subtitles:
            groupId = variant?.attributes.subtitleGroupId
        case .closedCaptions:
            groupId = variant?.attributes.closedCaptionGroupId
        }

        let candidates = orderedRenditionInfos
            .map(\.rendition)
            .filter { $0.type == kind && (groupId == nil || $0.groupId == groupId) }
        if let preferred = candidates.first(where: { $0.isDefault }) {
            return preferred
        }
        if let autoselect = candidates.first(where: { $0.isAutoSelect }) {
            return autoselect
        }
        return candidates.first
    }

    private func updateActiveRendition(
        _ rendition: HLSManifest.Rendition?,
        for kind: HLSManifest.Rendition.Kind,
        notify: Bool
    ) {
        switch kind {
        case .audio:
            if activeAudioRendition?.id == rendition?.id { break }
            activeAudioRendition = rendition
        case .subtitles:
            if activeSubtitleRendition?.id == rendition?.id { break }
            activeSubtitleRendition = rendition
        case .closedCaptions:
            break
        }
        applyActiveRenditionsToPlayer()
        if notify {
            diagnostics.onRenditionChanged?(kind, rendition)
        }
    }

    private func applyActiveRenditionsToPlayer() {
        mediaSelectionTask?.cancel()
        guard player?.currentItem != nil else {
            mediaSelectionTask = nil
            return
        }
        mediaSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.selectMediaOption(for: self.activeAudioRendition, kind: .audio)
            if Task.isCancelled { return }
            await self.selectMediaOption(for: self.activeSubtitleRendition, kind: .subtitles)
        }
    }

    @MainActor
    private func selectMediaOption(for rendition: HLSManifest.Rendition?, kind: HLSManifest.Rendition.Kind) async {
        if Task.isCancelled { return }
        guard let item = player?.currentItem else { return }
        let characteristic: AVMediaCharacteristic
        switch kind {
        case .audio:
            characteristic = .audible
        case .subtitles, .closedCaptions:
            characteristic = .legible
        }
        let group: AVMediaSelectionGroup?
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            do {
                group = try await item.asset.loadMediaSelectionGroup(for: characteristic)
            } catch is CancellationError {
                return
            } catch {
                logger.log("Failed to load media selection group for \(characteristic.rawValue): \(error)", category: .player)
                return
            }
        } else {
            group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
        }
        if Task.isCancelled { return }
        guard player?.currentItem === item else { return }
        guard let group else { return }
        guard let rendition else {
            item.select(nil, in: group)
            return
        }
        if let option = group.options.first(where: { optionMatches($0, rendition: rendition) }) {
            item.select(option, in: group)
        }
    }

    private func optionMatches(_ option: AVMediaSelectionOption, rendition: HLSManifest.Rendition) -> Bool {
        if option.displayName == rendition.name {
            return true
        }
        if let language = rendition.language {
            if option.extendedLanguageTag == language {
                return true
            }
            if let locale = option.locale, locale.identifier == language {
                return true
            }
        }
        return false
    }

    private func metricsHandler() -> ProxyRouter.Handler {
        MetricsHandler(cache: cache, scheduler: scheduler).makeHandler()
    }

    private func refreshPlaylist(bufferState: BufferState) async {
        guard
            let playlist = currentPlaylist,
            let config = currentRewriteConfiguration
        else { return }

        let playlistText = await manifestProcessor.rewrite(
            mediaPlaylist: playlist,
            config: config,
            bufferState: bufferState
        )
        await playlistStore.update(playlistText, for: PlaylistStore.Identifier.primaryVariant)
    }

    private func handleBufferStateChange(_ bufferState: BufferState) async {
        latestBufferState = bufferState
        await updatePlaybackState(with: bufferState)
        await evaluateABR(bufferState: bufferState)
    }

    private func startPlaylistRefresh(at url: URL, generation: UInt64) async {
        await playlistRefresher.start(
            url: url,
            allowInsecure: configuration.allowInsecureManifests,
            retryPolicy: configuration.manifestRetryPolicy,
            onUpdate: { [weak self] playlist in
                guard let self else { return }
                await self.handleRefreshedPlaylist(playlist, generation: generation)
            }
        )
    }

    private func handleRefreshedPlaylist(_ playlist: MediaPlaylist, generation: UInt64) async {
        guard generation == sessionGeneration else { return }
        var didResetTimeline = false
        if let currentPlaylist,
           playlist.mediaSequence < currentPlaylist.mediaSequence
            || playlist.discontinuitySequence != currentPlaylist.discontinuitySequence {
            await cache.clear()
            didResetTimeline = true
        }
        currentPlaylist = playlist
        if didResetTimeline {
            resetPlaybackTimeline(with: playlist)
        } else {
            extendPlaybackTimeline(with: playlist)
        }
        updateKeyDiagnostics(for: playlist)
        await segmentCatalog.update(with: playlist, namespace: SegmentCatalog.Namespace.primary)
        await scheduler.updatePlaylist(playlist)
        let bufferState = await scheduler.bufferState()
        latestBufferState = bufferState
        await updatePlaybackState(with: bufferState)
        await evaluateABR(bufferState: bufferState)
        let metrics = await playlistRefresher.metrics()
        diagnostics.onPlaylistRefreshed?(metrics)
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

    private static func diskDirectory(
        for policy: ProxyPlayerConfiguration.CachePolicy,
        identifier: String
    ) -> URL? {
        guard policy.enableDiskCache else { return nil }
        if let directory = policy.diskDirectory {
            return directory
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSProxyCache", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    private static func abrPolicy(from configuration: ProxyPlayerConfiguration) -> AdaptiveVariantController.Policy {
        AdaptiveVariantController.Policy(
            minimumBitrateRatio: configuration.abrPolicy.minimumBitrateRatio,
            maximumBitrateRatio: configuration.abrPolicy.maximumBitrateRatio,
            hysteresisPercent: configuration.abrPolicy.hysteresisPercent,
            minimumSwitchInterval: configuration.abrPolicy.minimumSwitchInterval,
            failureDowngradeThreshold: configuration.abrPolicy.failureDowngradeThreshold
        )
    }

    private func applyConfiguration() async {
        await cache.updateConfiguration(
            capacityBytes: configuration.cachePolicy.memoryCapacityBytes,
            diskDirectory: ProxyHLSPlayer.diskDirectory(
                for: configuration.cachePolicy,
                identifier: cacheDirectoryIdentifier
            ),
            diskCapacityBytes: configuration.cachePolicy.diskCapacityBytes
        )
        await segmentFetcher.updateValidationPolicy(configuration.segmentValidation)
        let partBufferCount = configuration.lowLatencyPolicy.isEnabled ? configuration.lowLatencyPolicy.targetPartBufferCount : 0
        await scheduler.updateConfiguration(.init(
            targetBufferSeconds: configuration.bufferPolicy.targetBufferSeconds,
            maxSegments: configuration.bufferPolicy.maxPrefetchSegments,
            targetPartCount: partBufferCount
        ))
        await playlistRefresher.updateConfiguration(.init(
            refreshInterval: configuration.bufferPolicy.refreshInterval,
            maxBackoffInterval: configuration.bufferPolicy.maxRefreshBackoff
        ))
        if configuration.lowLatencyPolicy.isEnabled {
            await playlistRefresher.updateLowLatencyConfiguration(.init(
                isEnabled: true,
                blockingRequestTimeout: configuration.lowLatencyPolicy.blockingRequestTimeout,
                enableDeltaUpdates: configuration.lowLatencyOptions?.enableDeltaUpdates ?? false
            ))
        } else {
            await playlistRefresher.updateLowLatencyConfiguration(nil)
        }
        await scheduler.enqueueUpcomingPlaylists(configuration.upcomingPlaylists)
        await scheduler.onTelemetry(makeTelemetryHandler())
        await throughputEstimator.updateConfiguration(.init(window: configuration.abrPolicy.estimatorWindow))
        await adaptiveController.updatePolicy(Self.abrPolicy(from: configuration))
    }

    private func keyURLResolver(for baseURL: URL) -> HLSRewriteConfiguration.KeyURLResolver? {
        guard configuration.drmPolicy == .proxy else { return nil }
        let keyBaseURL = baseURL
            .appendingPathComponent("assets")
            .appendingPathComponent(AuxiliaryAssetType.keys.rawValue)
        return { key in
            guard let uri = key.uri else { return nil }
            let identifier = ProxyHLSPlayer.keyIdentifier(forKeyURI: uri)
            return keyBaseURL.appendingPathComponent(identifier)
        }
    }

    private func updateKeyDiagnostics(for playlist: MediaPlaylist) {
        let statuses = sanitizedKeyStatuses(for: playlist)
        guard statuses != latestKeyStatuses else { return }
        latestKeyStatuses = statuses
        diagnostics.onKeyMetadataChanged?(statuses)
    }

    private func sanitizedKeyStatuses(for playlist: MediaPlaylist) -> [ProxyPlayerDiagnostics.KeyStatus] {
        var seen: Set<ProxyPlayerDiagnostics.KeyStatus> = []
        var statuses: [ProxyPlayerDiagnostics.KeyStatus] = []
        for key in playlist.sessionKeys {
            guard let status = keyStatus(from: key, isSessionKey: true) else { continue }
            if seen.insert(status).inserted {
                statuses.append(status)
            }
        }
        for segment in playlist.segments {
            guard let encryption = segment.encryption else { continue }
            guard let status = keyStatus(from: encryption.key, isSessionKey: false) else { continue }
            if seen.insert(status).inserted {
                statuses.append(status)
            }
        }
        return statuses
    }

    private func keyStatus(from key: HLSKey, isSessionKey: Bool) -> ProxyPlayerDiagnostics.KeyStatus? {
        let identifier: String
        if let uri = key.uri {
            identifier = ProxyHLSPlayer.keyIdentifier(forKeyURI: uri)
        } else {
            identifier = ProxyHLSPlayer.digest(for: "\(key.method.rawValue)-none")
        }
        return ProxyPlayerDiagnostics.KeyStatus(method: key.method, uriHash: identifier, isSessionKey: isSessionKey)
    }

    private func makeTelemetryHandler() -> (@Sendable (SegmentPrefetchScheduler.Telemetry) async -> Void) {
        let controller = adaptiveController
        return { [weak self, logger, controller] telemetry in
            logger.log(
                "scheduled=\(telemetry.scheduledSequences) ready=\(telemetry.readyCount) parts=\(telemetry.readyPartCount) failures=\(telemetry.failureCount)",
                category: .scheduler
            )
            guard telemetry.failureCount > 0 else { return }
            await controller.registerFailure()
            guard let player = await MainActor.run(resultType: ProxyHLSPlayer?.self, body: { self }) else { return }
            await player.evaluateABR(bufferState: nil)
        }
    }

    private func makeSegmentMetricsHandler() -> (@Sendable (HLSSegmentFetcher.FetchMetrics) async -> Void) {
        let estimator = throughputEstimator
        let controller = adaptiveController
        return { [weak self, estimator, controller] metrics in
            await estimator.ingest(metrics)
            await controller.resetFailures()
            guard let player = await MainActor.run(resultType: ProxyHLSPlayer?.self, body: { self }) else { return }
            await player.evaluateABR(bufferState: nil)
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

    private func evaluateABR(bufferState providedState: BufferState?) async {
        guard
            configuration.abrPolicy.isEnabled,
            let rewriteConfiguration = currentRewriteConfiguration,
            case .automatic = rewriteConfiguration.qualityPolicy,
            variants.count > 1,
            let currentVariant = activeVariant,
            !abrSwitchInProgress
        else { return }

        guard let throughputSample = await throughputEstimator.sample() else { return }
        let state: BufferState
        if let providedState {
            state = providedState
        } else if let latestBufferState {
            state = latestBufferState
        } else {
            state = await scheduler.bufferState()
        }
        latestBufferState = state
        let decision = await adaptiveController.evaluate(
            currentVariant: currentVariant,
            qualityPolicy: rewriteConfiguration.qualityPolicy,
            throughputSample: throughputSample,
            bufferState: state
        )

        if decision.action == .switchVariant,
           let target = decision.targetVariant,
           target != currentVariant {
            await performVariantSwitch(to: target, reason: decision.reason, bufferState: state)
        }
    }

    private func performVariantSwitch(
        to variant: VariantPlaylist,
        reason: AdaptiveVariantController.Reason,
        bufferState: BufferState?
    ) async {
        guard !abrSwitchInProgress else { return }
        abrSwitchInProgress = true
        defer { abrSwitchInProgress = false }

        do {
            let playlist = try await fetchVariantPlaylist(for: variant)
            let referenceState: BufferState
            if let bufferState {
                referenceState = bufferState
            } else if let latestBufferState {
                referenceState = latestBufferState
            } else {
                referenceState = await scheduler.bufferState()
            }
            let alignedPlaylist = align(playlist: playlist, to: referenceState)
            activeVariant = variant
            updateRenditionSelections(for: variant)
            currentPlaylist = alignedPlaylist
            extendPlaybackTimeline(with: alignedPlaylist)
            updateKeyDiagnostics(for: alignedPlaylist)
            await scheduler.stop()
            await segmentCatalog.update(with: alignedPlaylist, namespace: SegmentCatalog.Namespace.primary)
            await scheduler.enqueueUpcomingPlaylists(configuration.upcomingPlaylists)
            await scheduler.start(playlist: alignedPlaylist, fetcher: segmentFetcher, cache: cache)
            await playlistRefresher.stop()
            await startPlaylistRefresh(at: variant.url, generation: sessionGeneration)
            diagnostics.onQualityChanged?(variant)
            latestBufferState = referenceState
            await refreshPlaylist(bufferState: referenceState)
            await updateMasterPlaylist()
            logger.log("ABR switched to variant \(variant.url.absoluteString) due to \(reason)", category: .player)
        } catch {
            logger.log("Failed to switch variant: \(error)", category: .player)
        }
    }

    private func fetchVariantPlaylist(for variant: VariantPlaylist) async throws -> MediaPlaylist {
        let text = try await fetchManifestText(from: variant.url)
        let manifest = try await manifestProcessor.parse(text, baseURL: variant.url)
        guard let playlist = manifest.mediaPlaylist else {
            throw URLError(.badServerResponse)
        }
        return playlist
    }

    private func align(playlist: MediaPlaylist, to bufferState: BufferState?) -> MediaPlaylist {
        guard let floor = bufferState?.playedThroughSequence else { return playlist }
        let minimumSequence = floor + 1
        let visibleSegments = playlist.segments.drop { $0.sequence < minimumSequence }
        guard !visibleSegments.isEmpty else { return playlist }
        return MediaPlaylist(
            protocolVersion: playlist.protocolVersion,
            targetDuration: playlist.targetDuration,
            mediaSequence: visibleSegments.first?.sequence ?? playlist.mediaSequence,
            segments: Array(visibleSegments),
            isEndlist: playlist.isEndlist,
            sessionKeys: playlist.sessionKeys,
            partTargetDuration: playlist.partTargetDuration,
            serverControl: playlist.serverControl,
            preloadHints: playlist.preloadHints,
            renditionReports: playlist.renditionReports,
            skippedSegmentCount: playlist.skippedSegmentCount,
            independentSegments: playlist.independentSegments,
            playlistType: playlist.playlistType,
            startTag: playlist.startTag,
            discontinuitySequence: playlist.discontinuitySequence,
            passthroughTags: playlist.passthroughTags,
            trailingParts: playlist.trailingParts
        )
    }

    private func shouldDelayPlayback(for bufferState: BufferState) -> Bool {
        configuration.bufferPolicy.hideUntilBuffered && bufferState.prefetchDepthSeconds <= 0
    }

    private func updatePlaybackState(with bufferState: BufferState) async {
        guard let rewriteConfiguration = currentRewriteConfiguration else { return }

        if shouldDelayPlayback(for: bufferState) {
            updateState(PlayerState(
                status: .buffering,
                bufferDepthSeconds: bufferState.prefetchDepthSeconds,
                qualityDescription: qualityDescription
            ))
            return
        }

        await refreshPlaylist(bufferState: bufferState)

        if !didPreparePlayerForCurrentLoad {
            preparePlayer(with: rewriteConfiguration.playlistURL)
            didPreparePlayerForCurrentLoad = true
        }

        updateState(PlayerState(
            status: .ready,
            bufferDepthSeconds: bufferState.prefetchDepthSeconds,
            qualityDescription: qualityDescription
        ))
    }

    private func updateState(_ state: PlayerState) {
        status = state.status
        bufferDepthSeconds = state.bufferDepthSeconds
        qualityDescription = state.qualityDescription
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }

    private func ensureActiveSession(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
    }
}
#else
public final class ProxyHLSPlayer {
    public init() {}
    public func load(from remoteURL: URL, quality: HLSRewriteConfiguration.QualityPolicy = .automatic) async {}
    public func play() {}
    public func pause() {}
    public func stop() {}

    public nonisolated static func keyIdentifier(forKeyURI uri: URL) -> String {
        digest(for: uri.absoluteString)
    }

    private nonisolated static func digest(for string: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
#endif
#if canImport(Observation) && canImport(AVFoundation)
private extension HLSManifest.Rendition.Kind {
    var supportedAssetType: AuxiliaryAssetType? {
        switch self {
        case .audio:
            return .audio
        case .subtitles:
            return .subtitles
        case .closedCaptions:
            return nil
        }
    }

    var attributeValue: String {
        switch self {
        case .audio:
            return "AUDIO"
        case .subtitles:
            return "SUBTITLES"
        case .closedCaptions:
            return "CLOSED-CAPTIONS"
        }
    }
}

private actor ManifestProcessor {
    private let parser = HLSParser()
    private let rewriter = HLSRewriter()

    func parse(_ text: String, baseURL: URL?) throws -> HLSManifest {
        try parser.parse(text, baseURL: baseURL)
    }

    func rewrite(
        mediaPlaylist: MediaPlaylist,
        config: HLSRewriteConfiguration,
        bufferState: BufferState,
        namespace: String? = nil
    ) -> String {
        rewriter.rewrite(
            mediaPlaylist: mediaPlaylist,
            config: config,
            bufferState: bufferState,
            namespace: namespace
        )
    }
}
#endif
