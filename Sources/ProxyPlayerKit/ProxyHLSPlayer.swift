import Foundation
import HLSCore
import LocalProxy
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Combine)
import Combine
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Combine) && canImport(AVFoundation)

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

@MainActor
public final class ProxyHLSPlayer: ObservableObject {
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
    }

    private enum PlaylistPaths {
        static let variant = "variants/main.m3u8"
    }

    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var state = PlayerState()
    @Published public private(set) var configuration: ProxyPlayerConfiguration
    @Published public private(set) var variants: [VariantPlaylist] = []
    @Published public private(set) var audioRenditions: [HLSManifest.Rendition] = []
    @Published public private(set) var subtitleRenditions: [HLSManifest.Rendition] = []
    @Published public private(set) var activeAudioRendition: HLSManifest.Rendition?
    @Published public private(set) var activeSubtitleRendition: HLSManifest.Rendition?

    private let logger: Logger
    private let parser = HLSParser()
    private let rewriter = HLSRewriter()
    private let cache: HLSSegmentCache
    private let scheduler: SegmentPrefetchScheduler
    private let playlistRefresher: PlaylistRefreshController
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
    private let throughputEstimator: ThroughputEstimator
    private let adaptiveController: AdaptiveVariantController
    private var activeVariant: VariantPlaylist?
    private var abrSwitchInProgress = false
    private var latestBufferState: BufferState?
    private var resolvedRenditions: [String: ResolvedRenditionInfo] = [:]
    private var orderedRenditionInfos: [ResolvedRenditionInfo] = []
    private var renditionPlaylists: [String: MediaPlaylist] = [:]
    private var auxiliaryRegistrations: [AuxiliaryRegistration] = []
    private var latestManifestRenditions: [HLSManifest.Rendition] = []
    private var latestKeyStatuses: [ProxyPlayerDiagnostics.KeyStatus] = []
    private var shouldPlayWhenReady = false

    public init(
        configuration: ProxyPlayerConfiguration = .init(),
        logger: Logger = ProxyPlayerLogger(),
        diagnostics: ProxyPlayerDiagnostics = .init()
    ) {
        self.configuration = configuration
        self.logger = logger
        self.diagnostics = diagnostics
        self.throughputEstimator = ThroughputEstimator(configuration: .init(window: configuration.abrPolicy.estimatorWindow))
        self.adaptiveController = AdaptiveVariantController(policy: Self.abrPolicy(from: configuration), logger: logger)
        self.segmentFetcher = HLSSegmentFetcher(validationPolicy: configuration.segmentValidation)
        self.cache = HLSSegmentCache(
            capacity: configuration.cachePolicy.memoryCapacity,
            diskDirectory: ProxyHLSPlayer.diskDirectory(for: configuration.cachePolicy)
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

        Task {
            await segmentFetcher.onMetrics(makeSegmentMetricsHandler())
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
        shouldPlayWhenReady = true
        player?.play()
    }

    public func pause() {
        shouldPlayWhenReady = false
        player?.pause()
    }

    public func stop() {
        shouldPlayWhenReady = false
        player?.pause()
        player = nil
        didPreparePlayerForCurrentLoad = false
        variants = []
        activeVariant = nil
        abrSwitchInProgress = false
        latestBufferState = nil
        Task {
            await scheduler.onBufferStateChange(nil)
            await scheduler.onTelemetry(nil)
            await scheduler.stop()
            await playlistRefresher.stop()
            await clearResolvedRenditions()
        }
        server.stop()
        latestKeyStatuses = []
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
        Task { await updateMasterPlaylist() }
    }

    public func registerAuxiliaryAsset(
        data: Data,
        identifier: String,
        type: AuxiliaryAssetType,
        rendition: AuxiliaryRenditionRegistration? = nil
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
        auxiliaryRegistrations.append(.init(identifier: identifier, type: type, descriptor: rendition))
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
        await clearResolvedRenditions()
        await throughputEstimator.reset()
        await adaptiveController.reset()

        let baseURL = try await waitForBaseURL()

        let playlistResult = try await fetchMediaPlaylist(from: remoteURL, quality: quality)
        variants = playlistResult.variants
        await adaptiveController.updateVariants(playlistResult.variants)
        if let variant = playlistResult.selectedVariant {
            activeVariant = variant
            diagnostics.onQualityChanged?(variant)
        } else {
            activeVariant = nil
        }
        let playlist = playlistResult.playlist
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
        logger.log("Proxy base URL: \(baseURL.absoluteString)", category: .player)

        let lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions?
        if configuration.lowLatencyPolicy.isEnabled {
            lowLatencyOptions = configuration.lowLatencyOptions
        } else {
            lowLatencyOptions = nil
        }

        let rewriteConfiguration = HLSRewriteConfiguration(
            proxyBaseURL: baseURL,
            hideUntilBuffered: configuration.bufferPolicy.hideUntilBuffered,
            artificialBandwidth: lowLatencyOptions?.canSkipUntil.map { Int($0 * 1_000_000) },
            qualityPolicy: quality,
            lowLatencyOptions: lowLatencyOptions,
            keyURLResolver: keyURLResolver(for: baseURL)
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
        scheduleRenditionPlaylists(config: rewriteConfiguration)
        await updateMasterPlaylist()
        await updatePlaybackState(with: bufferState)
        await startPlaylistRefresh(at: playlistResult.url)
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
        applyActiveRenditionsToPlayer()
        if shouldPlayWhenReady {
            player?.play()
        }
    }

    private func fetchMediaPlaylist(
        from url: URL,
        quality: HLSRewriteConfiguration.QualityPolicy
    ) async throws -> (
        playlist: MediaPlaylist,
        url: URL,
        variants: [VariantPlaylist],
        renditions: [HLSManifest.Rendition],
        selectedVariant: VariantPlaylist?
    ) {
        let text = try await fetchManifestText(from: url)
        let manifest = try parser.parse(text, baseURL: url)

        if let playlist = manifest.mediaPlaylist {
            return (playlist, url, manifest.variants, manifest.renditions, nil)
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
        return (result.playlist, result.url, manifest.variants, renditions, selectedVariant)
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
        orderedRenditionInfos.removeAll()
        resolvedRenditions.removeAll()
        renditionPlaylists.removeAll()
        audioRenditions = []
        subtitleRenditions = []
        activeAudioRendition = nil
        activeSubtitleRendition = nil
        latestManifestRenditions = []
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
                instreamId: rendition.instreamId
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
            let rendition = HLSManifest.Rendition(
                type: descriptor.kind,
                groupId: descriptor.groupId,
                name: descriptor.name,
                language: descriptor.language,
                isDefault: descriptor.isDefault,
                isAutoSelect: descriptor.isAutoSelect,
                isForced: descriptor.isForced,
                characteristics: descriptor.characteristics,
                uri: assetURL
            )
            append(ResolvedRenditionInfo(
                rendition: rendition,
                remoteURI: nil,
                namespace: nil,
                playlistIdentifier: nil,
                assetType: registration.type
            ))
        }

        orderedRenditionInfos = ordered
        resolvedRenditions = lookup
        audioRenditions = ordered.filter { $0.rendition.type == .audio }.map(\.rendition)
        subtitleRenditions = ordered.filter { $0.rendition.type == .subtitles }.map(\.rendition)
    }

    private func scheduleRenditionPlaylists(config: HLSRewriteConfiguration) {
        for info in orderedRenditionInfos where info.remoteURI != nil {
            Task { [weak self] in
                guard let self else { return }
                await self.fetchRenditionPlaylist(info: info, config: config)
            }
        }
    }

    private func fetchRenditionPlaylist(info: ResolvedRenditionInfo, config: HLSRewriteConfiguration) async {
        guard
            let remoteURL = info.remoteURI,
            let namespace = info.namespace,
            let playlistIdentifier = info.playlistIdentifier
        else { return }
        do {
            let text = try await fetchManifestText(from: remoteURL)
            let manifest = try parser.parse(text, baseURL: remoteURL)
            guard let playlist = manifest.mediaPlaylist else {
                logger.log("Rendition playlist missing media body for \(info.rendition.name)", category: .player)
                return
            }
            await segmentCatalog.update(with: playlist, namespace: namespace)
            let rewritten = rewriter.rewrite(
                mediaPlaylist: playlist,
                config: config,
                bufferState: BufferState(),
                namespace: namespace
            )
            await playlistStore.update(rewritten, for: playlistIdentifier)
            renditionPlaylists[info.rendition.id] = playlist
        } catch {
            logger.log("Failed to load rendition \(info.rendition.name): \(error)", category: .player)
        }
    }

    private func updateMasterPlaylist() async {
        guard let config = currentRewriteConfiguration else { return }
        let variantURL = config.proxyBaseURL.appendingPathComponent(PlaylistPaths.variant)
        let text = buildMasterPlaylist(variantURL: variantURL)
        await playlistStore.update(text, for: PlaylistStore.Identifier.master)
    }

    private func buildMasterPlaylist(variantURL: URL) -> String {
        var lines: [String] = ["#EXTM3U", "#EXT-X-VERSION:3"]
        for info in orderedRenditionInfos {
            var attributes: [String] = []
            attributes.append("TYPE=\(info.rendition.type.attributeValue)")
            attributes.append("GROUP-ID=\"\(info.rendition.groupId)\"")
            attributes.append("NAME=\"\(info.rendition.name)\"")
            if let language = info.rendition.language {
                attributes.append("LANGUAGE=\"\(language)\"")
            }
            attributes.append("DEFAULT=\(isActive(rendition: info.rendition) ? "YES" : (info.rendition.isDefault ? "YES" : "NO"))")
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
        selectMediaOption(for: activeAudioRendition, kind: .audio)
        selectMediaOption(for: activeSubtitleRendition, kind: .subtitles)
    }

    private func selectMediaOption(for rendition: HLSManifest.Rendition?, kind: HLSManifest.Rendition.Kind) {
        guard let item = player?.currentItem else { return }
        let characteristic: AVMediaCharacteristic
        switch kind {
        case .audio:
            characteristic = .audible
        case .subtitles, .closedCaptions:
            characteristic = .legible
        }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return }
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

        let playlistText = rewriter.rewrite(
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

    private func startPlaylistRefresh(at url: URL) async {
        await playlistRefresher.start(
            url: url,
            allowInsecure: configuration.allowInsecureManifests,
            retryPolicy: configuration.manifestRetryPolicy,
            onUpdate: { [weak self] playlist in
            guard let self else { return }
            await self.handleRefreshedPlaylist(playlist)
            }
        )
    }

    private func handleRefreshedPlaylist(_ playlist: MediaPlaylist) async {
        currentPlaylist = playlist
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

    private static func diskDirectory(for policy: ProxyPlayerConfiguration.CachePolicy) -> URL? {
        guard policy.enableDiskCache else { return nil }
        if let directory = policy.diskDirectory {
            return directory
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("HLSProxyCache", isDirectory: true)
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
            capacity: configuration.cachePolicy.memoryCapacity,
            diskDirectory: ProxyHLSPlayer.diskDirectory(for: configuration.cachePolicy)
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
            updateKeyDiagnostics(for: alignedPlaylist)
            await scheduler.stop()
            await cache.clear()
            await segmentCatalog.update(with: alignedPlaylist, namespace: SegmentCatalog.Namespace.primary)
            await scheduler.enqueueUpcomingPlaylists(configuration.upcomingPlaylists)
            await scheduler.start(playlist: alignedPlaylist, fetcher: segmentFetcher, cache: cache)
            await playlistRefresher.stop()
            await startPlaylistRefresh(at: variant.url)
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
        let manifest = try parser.parse(text, baseURL: variant.url)
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
            targetDuration: playlist.targetDuration,
            mediaSequence: visibleSegments.first?.sequence ?? playlist.mediaSequence,
            segments: Array(visibleSegments),
            isEndlist: playlist.isEndlist
        )
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
#if canImport(Combine) && canImport(AVFoundation)
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
#endif
