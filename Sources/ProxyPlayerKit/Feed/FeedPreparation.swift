import Foundation
import HLSCore

/// One bounded request from ``FeedCoordinator`` to a preparation backend.
public struct FeedPreparationRequest: Sendable, Equatable {
    public let item: FeedPlaybackItem
    public let generation: FeedNavigationGeneration
    public let role: FeedPlan.Role
    public let maximumLeadingSegments: Int
    public let maximumConcurrentFetches: Int
    public let qualityPolicy: HLSRewriteConfiguration.QualityPolicy

    public init(
        item: FeedPlaybackItem,
        generation: FeedNavigationGeneration,
        role: FeedPlan.Role,
        maximumLeadingSegments: Int,
        maximumConcurrentFetches: Int,
        qualityPolicy: HLSRewriteConfiguration.QualityPolicy = .automatic
    ) {
        self.item = item
        self.generation = generation
        self.role = role
        self.maximumLeadingSegments = max(1, maximumLeadingSegments)
        self.maximumConcurrentFetches = max(1, maximumConcurrentFetches)
        self.qualityPolicy = qualityPolicy
    }
}

/// Cache and origin work completed before a feed item is handed to a player.
public struct FeedPreparedItem: Sendable, Equatable {
    public let itemID: FeedItemID
    public let generation: FeedNavigationGeneration
    public let manifestURLs: [URL]
    public let mediaPlaylistCount: Int
    public let leadingSegmentCount: Int
    public let preparedResourceCount: Int
    public let preparedByteCount: Int
    public let cacheHitCount: Int
    public let originFetchCount: Int
    public let cacheHitByteCount: Int
    public let originFetchByteCount: Int
    /// `true` when the coordinator satisfied this generation from its bounded
    /// preparation cache without asking the backend to prepare it again.
    public let isPreparationReuse: Bool
    /// Validated live-window metadata for `.live` feed sources.
    public let liveWindow: HLSLiveWindow?

    public init(
        itemID: FeedItemID,
        generation: FeedNavigationGeneration,
        manifestURLs: [URL],
        mediaPlaylistCount: Int,
        leadingSegmentCount: Int,
        preparedResourceCount: Int,
        preparedByteCount: Int,
        cacheHitCount: Int,
        originFetchCount: Int,
        cacheHitByteCount: Int = 0,
        originFetchByteCount: Int = 0,
        isPreparationReuse: Bool = false,
        liveWindow: HLSLiveWindow? = nil
    ) {
        self.itemID = itemID
        self.generation = generation
        self.manifestURLs = manifestURLs
        self.mediaPlaylistCount = max(0, mediaPlaylistCount)
        self.leadingSegmentCount = max(0, leadingSegmentCount)
        self.preparedResourceCount = max(0, preparedResourceCount)
        self.preparedByteCount = max(0, preparedByteCount)
        self.cacheHitCount = max(0, cacheHitCount)
        self.originFetchCount = max(0, originFetchCount)
        self.cacheHitByteCount = max(0, cacheHitByteCount)
        self.originFetchByteCount = max(0, originFetchByteCount)
        self.isPreparationReuse = isPreparationReuse
        self.liveWindow = liveWindow
    }
}

/// A cancellation-cooperative backend used by the feed coordinator.
public protocol FeedPreparing: Sendable {
    func update(policy: FeedPlaybackPolicy) async throws
    func prepare(_ request: FeedPreparationRequest) async throws -> FeedPreparedItem
}

public extension FeedPreparing {
    func update(policy: FeedPlaybackPolicy) async throws {
        _ = try policy.validated()
    }
}

public enum FeedPreparationError: Error, Equatable, LocalizedError, Sendable {
    case emptyClipSequence(FeedItemID)
    case manifestCycle(URL)
    case manifestDepthExceeded(URL)
    case noPlayableVariant(URL)
    case expectedLivePlaylist(FeedItemID)
    case invalidLiveWindow(FeedItemID, HLSLiveTimeline.UnavailabilityReason)

    public var errorDescription: String? {
        switch self {
        case .emptyClipSequence(let itemID):
            "Clip sequence is empty for feed item: \(itemID)"
        case .manifestCycle(let url):
            "Manifest cycle detected at: \(url.absoluteString)"
        case .manifestDepthExceeded(let url):
            "Manifest nesting exceeds the supported depth at: \(url.absoluteString)"
        case .noPlayableVariant(let url):
            "Master manifest has no playable variant: \(url.absoluteString)"
        case .expectedLivePlaylist(let itemID):
            "Expected a live playlist for feed item: \(itemID)"
        case .invalidLiveWindow(let itemID, let reason):
            "Invalid live window for feed item \(itemID): \(String(describing: reason))"
        }
    }
}

/// Production manifest and leading-segment preparation with shared cache reuse.
///
/// The backend follows the same automatic startup-variant rule as
/// ``ProxyHLSPlayer``, fetches only the coordinator-provided leading segment
/// budget, and admits every network operation through one global/per-origin
/// limiter. Manifests, initialization maps, encryption keys, and media segments
/// all share the configured memory/disk cache.
public actor HLSFeedPreparationBackend: FeedPreparing {
    private struct ResolvedPlaylist: Sendable {
        let playlist: MediaPlaylist
        let manifestURLs: [URL]
        let cacheHitCount: Int
        let originFetchCount: Int
        let cacheHitByteCount: Int
        let originFetchByteCount: Int
    }

    private struct Resource: Hashable, Sendable {
        let key: String
        let url: URL
        let byteRange: ClosedRange<Int>?
    }

    private struct ResourceOutcome: Sendable {
        let byteCount: Int
        let cacheHitCount: Int
        let originFetchCount: Int
        let cacheHitByteCount: Int
        let originFetchByteCount: Int
    }

    private var policy: FeedPlaybackPolicy
    private let allowsInsecureManifests: Bool
    private var manifestSession: URLSession
    private let managesManifestSession: Bool
    private let parser = HLSParser()
    private let segmentSource: any SegmentSource
    private let managedSegmentFetcher: HLSSegmentFetcher?
    private let cache: HLSSegmentCache
    private let limiter: FeedFetchLimiter

    deinit {
        if managesManifestSession { manifestSession.invalidateAndCancel() }
    }

    public init(
        policy: FeedPlaybackPolicy,
        allowsInsecureManifests: Bool = false,
        session: URLSession? = nil,
        segmentSource: (any SegmentSource)? = nil,
        cache: HLSSegmentCache? = nil
    ) throws {
        let validatedPolicy = try policy.validated()
        self.policy = validatedPolicy
        self.allowsInsecureManifests = allowsInsecureManifests
        self.manifestSession = session ?? validatedPolicy.network.makeURLSession()
        self.managesManifestSession = session == nil

        let fetcher: HLSSegmentFetcher?
        if let segmentSource {
            self.segmentSource = segmentSource
            fetcher = nil
        } else {
            let value = HLSSegmentFetcher(
                session: session,
                networkPolicy: validatedPolicy.network,
                retryPolicy: validatedPolicy.retry.segment
            )
            self.segmentSource = value
            fetcher = value
        }
        self.managedSegmentFetcher = fetcher

        let diskDirectory = Self.diskDirectory(for: validatedPolicy)
        self.cache = cache ?? HLSSegmentCache(
            capacityBytes: validatedPolicy.budget.memoryCacheBytes,
            diskDirectory: diskDirectory,
            diskCapacityBytes: validatedPolicy.budget.diskCacheBytes,
            timeToLive: validatedPolicy.eviction.timeToLive,
            maximumEntryCount: validatedPolicy.budget.maximumCacheEntryCount
        )
        self.limiter = FeedFetchLimiter(
            globalLimit: validatedPolicy.concurrency.maximumConcurrentFetches,
            perOriginLimit: validatedPolicy.network.maximumConnectionsPerHost
        )
    }

    public func update(policy: FeedPlaybackPolicy) async throws {
        let validatedPolicy = try policy.validated()
        if managesManifestSession, validatedPolicy.network != self.policy.network {
            let previousSession = manifestSession
            manifestSession = validatedPolicy.network.makeURLSession()
            previousSession.finishTasksAndInvalidate()
        }
        self.policy = validatedPolicy
        await limiter.updateLimits(
            global: validatedPolicy.concurrency.maximumConcurrentFetches,
            perOrigin: validatedPolicy.network.maximumConnectionsPerHost
        )
        if let managedSegmentFetcher {
            await managedSegmentFetcher.updateNetworkPolicy(validatedPolicy.network)
            await managedSegmentFetcher.updateRetryPolicy(validatedPolicy.retry.segment)
        }
        await cache.updateConfiguration(
            capacityBytes: validatedPolicy.budget.memoryCacheBytes,
            diskDirectory: Self.diskDirectory(for: validatedPolicy),
            diskCapacityBytes: validatedPolicy.budget.diskCacheBytes,
            timeToLive: validatedPolicy.eviction.timeToLive,
            maximumEntryCount: validatedPolicy.budget.maximumCacheEntryCount
        )
    }

    public func prepare(_ request: FeedPreparationRequest) async throws -> FeedPreparedItem {
        try Task.checkCancellation()
        let sourceURLs: [URL]
        let sourceKind: FeedStreamKind
        let compatibleClips: [ProxyPlaybackClip]?
        switch request.item.source {
        case .stream(let url, let kind):
            sourceURLs = [url]
            sourceKind = kind
            compatibleClips = nil
        case .clips(let urls):
            guard !urls.isEmpty else {
                throw FeedPreparationError.emptyClipSequence(request.item.id)
            }
            sourceURLs = Array(urls.prefix(request.maximumLeadingSegments))
            sourceKind = .videoOnDemand
            compatibleClips = nil
        case .compatibleClips(let clips):
            guard !clips.isEmpty else {
                throw FeedPreparationError.emptyClipSequence(request.item.id)
            }
            sourceURLs = clips.map(\.playlistURL)
            sourceKind = .videoOnDemand
            compatibleClips = clips
        }

        var resolvedPlaylists: [ResolvedPlaylist] = []
        for (clipIndex, url) in sourceURLs.enumerated() {
            try Task.checkCancellation()
            let resolved: ResolvedPlaylist
            if compatibleClips != nil {
                let loaded = try await loadManifest(from: url)
                guard loaded.manifest.kind == .media,
                      loaded.manifest.variants.isEmpty,
                      loaded.manifest.renditions.isEmpty,
                      let playlist = loaded.manifest.mediaPlaylist
                else {
                    throw HLSClipStitchingError.unsupportedMasterOrRenditionTopology(
                        clipIndex: clipIndex
                    )
                }
                resolved = ResolvedPlaylist(
                    playlist: playlist,
                    manifestURLs: [url],
                    cacheHitCount: loaded.cacheHitCount,
                    originFetchCount: loaded.originFetchCount,
                    cacheHitByteCount: loaded.cacheHitByteCount,
                    originFetchByteCount: loaded.originFetchByteCount
                )
            } else {
                resolved = try await resolveMediaPlaylist(
                    from: url,
                    qualityPolicy: request.qualityPolicy,
                    visited: [],
                    depth: 0
                )
            }
            resolvedPlaylists.append(resolved)
        }

        let mediaPlaylistCount = resolvedPlaylists.count
        if let compatibleClips {
            let stitched = try HLSClipStitcher().stitch(zip(compatibleClips, resolvedPlaylists).map {
                HLSClip(
                    id: $0.0.id,
                    playlist: $0.1.playlist,
                    mediaSignature: $0.0.mediaSignature
                )
            })
            resolvedPlaylists = [ResolvedPlaylist(
                playlist: stitched,
                manifestURLs: resolvedPlaylists.flatMap(\.manifestURLs),
                cacheHitCount: resolvedPlaylists.reduce(0) { $0 + $1.cacheHitCount },
                originFetchCount: resolvedPlaylists.reduce(0) { $0 + $1.originFetchCount },
                cacheHitByteCount: resolvedPlaylists.reduce(0) {
                    $0 + $1.cacheHitByteCount
                },
                originFetchByteCount: resolvedPlaylists.reduce(0) {
                    $0 + $1.originFetchByteCount
                }
            )]
        }

        let liveWindow: HLSLiveWindow?
        if sourceKind == .live, let playlist = resolvedPlaylists.first?.playlist {
            switch HLSLiveTimeline.state(for: playlist) {
            case .available(let window):
                liveWindow = window
            case .videoOnDemand:
                throw FeedPreparationError.expectedLivePlaylist(request.item.id)
            case .unavailable(let reason):
                throw FeedPreparationError.invalidLiveWindow(request.item.id, reason)
            }
        } else {
            liveWindow = nil
        }

        var resources: [Resource] = []
        var seenResourceKeys: Set<String> = []
        var leadingSegmentCount = 0
        var remainingSegments = request.maximumLeadingSegments

        for (index, resolved) in resolvedPlaylists.enumerated() where remainingSegments > 0 {
            let remainingSources = resolvedPlaylists.count - index - 1
            let allowance = index == 0
                ? max(1, remainingSegments - remainingSources)
                : min(1, remainingSegments)
            let segments: [HLSSegment]
            if sourceKind == .live {
                segments = Array(resolved.playlist.segments.suffix(allowance))
            } else {
                segments = Array(resolved.playlist.segments.prefix(allowance))
            }
            leadingSegmentCount += segments.count
            remainingSegments = max(0, remainingSegments - segments.count)

            for segment in segments {
                if let map = segment.initializationMap {
                    append(
                        Resource(
                            key: SegmentIdentity.key(for: map),
                            url: map.uri,
                            byteRange: map.byteRange
                        ),
                        to: &resources,
                        seenKeys: &seenResourceKeys
                    )
                }
                append(
                    Resource(
                        key: SegmentIdentity.key(for: segment),
                        url: segment.url,
                        byteRange: segment.byteRange
                    ),
                    to: &resources,
                    seenKeys: &seenResourceKeys
                )
            }
        }

        let outcomes = try await withThrowingTaskGroup(
            of: ResourceOutcome.self,
            returning: [ResourceOutcome].self
        ) { group in
            let concurrencyLimit = min(request.maximumConcurrentFetches, resources.count)
            var nextResourceIndex = 0
            while nextResourceIndex < concurrencyLimit {
                let resource = resources[nextResourceIndex]
                group.addTask { [self] in
                    try await fetch(resource)
                }
                nextResourceIndex += 1
            }
            var values: [ResourceOutcome] = []
            values.reserveCapacity(resources.count)
            for try await value in group {
                values.append(value)
                if nextResourceIndex < resources.count {
                    let resource = resources[nextResourceIndex]
                    group.addTask { [self] in
                        try await fetch(resource)
                    }
                    nextResourceIndex += 1
                }
            }
            return values
        }
        try Task.checkCancellation()

        let manifestURLs = resolvedPlaylists.flatMap(\.manifestURLs)
        let manifestCacheHits = resolvedPlaylists.reduce(0) { $0 + $1.cacheHitCount }
        let manifestOriginFetches = resolvedPlaylists.reduce(0) { $0 + $1.originFetchCount }
        let manifestCacheHitBytes = resolvedPlaylists.reduce(0) { $0 + $1.cacheHitByteCount }
        let manifestOriginBytes = resolvedPlaylists.reduce(0) { $0 + $1.originFetchByteCount }
        return FeedPreparedItem(
            itemID: request.item.id,
            generation: request.generation,
            manifestURLs: manifestURLs,
            mediaPlaylistCount: mediaPlaylistCount,
            leadingSegmentCount: leadingSegmentCount,
            preparedResourceCount: outcomes.count,
            preparedByteCount: outcomes.reduce(0) { $0 + $1.byteCount },
            cacheHitCount: manifestCacheHits + outcomes.reduce(0) { $0 + $1.cacheHitCount },
            originFetchCount: manifestOriginFetches + outcomes.reduce(0) { $0 + $1.originFetchCount },
            cacheHitByteCount: manifestCacheHitBytes + outcomes.reduce(0) {
                $0 + $1.cacheHitByteCount
            },
            originFetchByteCount: manifestOriginBytes + outcomes.reduce(0) {
                $0 + $1.originFetchByteCount
            },
            liveWindow: liveWindow
        )
    }

    public func cacheMetrics() async -> HLSSegmentCache.Metrics {
        await cache.metrics()
    }

    public func handleMemoryPressure() async {
        await cache.handleMemoryPressure()
    }

    private func resolveMediaPlaylist(
        from url: URL,
        qualityPolicy: HLSRewriteConfiguration.QualityPolicy,
        visited: Set<URL>,
        depth: Int
    ) async throws -> ResolvedPlaylist {
        guard depth <= 4 else {
            throw FeedPreparationError.manifestDepthExceeded(url)
        }
        guard !visited.contains(url) else {
            throw FeedPreparationError.manifestCycle(url)
        }
        var nextVisited = visited
        nextVisited.insert(url)

        let loaded = try await loadManifest(from: url)
        if let playlist = loaded.manifest.mediaPlaylist {
            return ResolvedPlaylist(
                playlist: playlist,
                manifestURLs: [url],
                cacheHitCount: loaded.cacheHitCount,
                originFetchCount: loaded.originFetchCount,
                cacheHitByteCount: loaded.cacheHitByteCount,
                originFetchByteCount: loaded.originFetchByteCount
            )
        }

        guard let variant = selectVariant(
            from: loaded.manifest.variants,
            policy: qualityPolicy
        ) else {
            throw FeedPreparationError.noPlayableVariant(url)
        }
        let nested = try await resolveMediaPlaylist(
            from: variant.url,
            qualityPolicy: qualityPolicy,
            visited: nextVisited,
            depth: depth + 1
        )
        return ResolvedPlaylist(
            playlist: nested.playlist,
            manifestURLs: [url] + nested.manifestURLs,
            cacheHitCount: loaded.cacheHitCount + nested.cacheHitCount,
            originFetchCount: loaded.originFetchCount + nested.originFetchCount,
            cacheHitByteCount: loaded.cacheHitByteCount + nested.cacheHitByteCount,
            originFetchByteCount: loaded.originFetchByteCount + nested.originFetchByteCount
        )
    }

    private func loadManifest(
        from url: URL
    ) async throws -> (
        manifest: HLSManifest,
        cacheHitCount: Int,
        originFetchCount: Int,
        cacheHitByteCount: Int,
        originFetchByteCount: Int
    ) {
        guard allowsInsecureManifests || url.scheme?.lowercased() == "https" else {
            throw HLSManifestFetcher.FetchError.insecureScheme
        }
        let key = "manifest-\(url.absoluteString)"
        let cached = await cache.entry(for: key, allowingExpired: true)
        if let cached, !cached.isExpired,
           let text = String(data: cached.data, encoding: .utf8) {
            return (try parser.parse(text, baseURL: url), 1, 0, cached.data.count, 0)
        }

        let currentPolicy = policy
        let session = manifestSession
        let allowInsecure = allowsInsecureManifests
        let response = try await limiter.withPermit(origin: Origin(url: url)) {
            let fetcher = HLSManifestFetcher(
                url: url,
                session: session,
                retryPolicy: currentPolicy.retry.manifest,
                networkPolicy: currentPolicy.network
            )
            return try await fetcher.fetchValidatedManifest(
                from: url,
                allowInsecure: allowInsecure,
                ifNoneMatch: cached?.validation?.eTag,
                ifModifiedSince: cached?.validation?.lastModified
            )
        }
        try Task.checkCancellation()
        switch response {
        case .notModified(let validation):
            guard let cached,
                  let text = String(data: cached.data, encoding: .utf8)
            else {
                throw HLSManifestFetcher.FetchError.invalidResponse(nil)
            }
            if validation.allowsStorage {
                await cache.put(
                    cached.data,
                    for: key,
                    validation: Self.cacheValidation(
                        validation,
                        fallingBackTo: cached.validation
                    )
                )
            } else {
                await cache.remove(key)
            }
            return (try parser.parse(text, baseURL: url), 1, 1, cached.data.count, 0)
        case .modified(let text, let validation):
            let data = Data(text.utf8)
            if validation.allowsStorage {
                await cache.put(
                    data,
                    for: key,
                    validation: Self.cacheValidation(validation)
                )
            } else {
                await cache.remove(key)
            }
            return (try parser.parse(text, baseURL: url), 0, 1, 0, data.count)
        }
    }

    private func fetch(_ resource: Resource) async throws -> ResourceOutcome {
        let cached = await cache.entry(for: resource.key, allowingExpired: true)
        if let cached, !cached.isExpired {
            return ResourceOutcome(
                byteCount: cached.data.count,
                cacheHitCount: 1,
                originFetchCount: 0,
                cacheHitByteCount: cached.data.count,
                originFetchByteCount: 0
            )
        }

        if let managedSegmentFetcher {
            let response = try await limiter.withPermit(origin: Origin(url: resource.url)) {
                try await managedSegmentFetcher.fetchValidatedResource(
                    at: resource.url,
                    byteRange: resource.byteRange,
                    ifNoneMatch: cached?.validation?.eTag,
                    ifModifiedSince: cached?.validation?.lastModified
                )
            }
            try Task.checkCancellation()
            switch response {
            case .notModified(let validation):
                guard let cached else {
                    throw HLSSegmentFetcher.FetchError.invalidResponse
                }
                if validation.allowsStorage {
                    await cache.put(
                        cached.data,
                        for: resource.key,
                        validation: Self.cacheValidation(
                            validation,
                            fallingBackTo: cached.validation
                        )
                    )
                } else {
                    await cache.remove(resource.key)
                }
                return ResourceOutcome(
                    byteCount: cached.data.count,
                    cacheHitCount: 1,
                    originFetchCount: 1,
                    cacheHitByteCount: cached.data.count,
                    originFetchByteCount: 0
                )
            case .modified(let data, let validation):
                if validation.allowsStorage {
                    await cache.put(
                        data,
                        for: resource.key,
                        validation: Self.cacheValidation(validation)
                    )
                } else {
                    await cache.remove(resource.key)
                }
                return ResourceOutcome(
                    byteCount: data.count,
                    cacheHitCount: 0,
                    originFetchCount: 1,
                    cacheHitByteCount: 0,
                    originFetchByteCount: data.count
                )
            }
        }

        let source = segmentSource
        let data = try await limiter.withPermit(origin: Origin(url: resource.url)) {
            try await source.fetchResource(at: resource.url, byteRange: resource.byteRange)
        }
        try Task.checkCancellation()
        await cache.put(data, for: resource.key)
        return ResourceOutcome(
            byteCount: data.count,
            cacheHitCount: 0,
            originFetchCount: 1,
            cacheHitByteCount: 0,
            originFetchByteCount: data.count
        )
    }

    private func selectVariant(
        from variants: [VariantPlaylist],
        policy: HLSRewriteConfiguration.QualityPolicy
    ) -> VariantPlaylist? {
        switch policy {
        case .automatic:
            variants.min {
                ($0.attributes.averageBandwidth ?? $0.attributes.bandwidth ?? Int.max)
                    < ($1.attributes.averageBandwidth ?? $1.attributes.bandwidth ?? Int.max)
            }
        case .locked(let profile):
            variants.first { profile.matches(bandwidth: $0.attributes.bandwidth) }
                ?? variants.first
        }
    }

    private func append(
        _ resource: Resource,
        to resources: inout [Resource],
        seenKeys: inout Set<String>
    ) {
        guard seenKeys.insert(resource.key).inserted else { return }
        resources.append(resource)
    }

    private static func diskDirectory(for policy: FeedPlaybackPolicy) -> URL? {
        guard policy.eviction.usesDiskCache else { return nil }
        if let directory = policy.eviction.diskDirectory {
            return directory
        }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("HLSProxyBuffer", isDirectory: true)
            .appendingPathComponent("FeedPreparation", isDirectory: true)
    }

    private static func cacheValidation(
        _ validation: HLSManifestFetcher.Validation,
        fallingBackTo fallback: HLSSegmentCache.ValidationMetadata? = nil
    ) -> HLSSegmentCache.ValidationMetadata {
        HLSSegmentCache.ValidationMetadata(
            eTag: validation.eTag ?? fallback?.eTag,
            lastModified: validation.lastModified ?? fallback?.lastModified,
            freshUntil: validation.maximumAge.map { Date().addingTimeInterval($0) }
        )
    }

    private static func cacheValidation(
        _ validation: HLSSegmentFetcher.OriginValidation,
        fallingBackTo fallback: HLSSegmentCache.ValidationMetadata? = nil
    ) -> HLSSegmentCache.ValidationMetadata {
        HLSSegmentCache.ValidationMetadata(
            eTag: validation.eTag ?? fallback?.eTag,
            lastModified: validation.lastModified ?? fallback?.lastModified,
            freshUntil: validation.maximumAge.map { Date().addingTimeInterval($0) }
        )
    }
}

private struct Origin: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init(url: URL) {
        self.scheme = url.scheme?.lowercased() ?? ""
        self.host = url.host?.lowercased() ?? ""
        self.port = url.port
    }
}

private actor FeedFetchLimiter {
    private struct Waiter {
        let id: UUID
        let origin: Origin
        let continuation: CheckedContinuation<Void, Error>
    }

    private var globalLimit: Int
    private var perOriginLimit: Int
    private var activeGlobal = 0
    private var activeByOrigin: [Origin: Int] = [:]
    private var waiters: [Waiter] = []

    init(globalLimit: Int, perOriginLimit: Int) {
        self.globalLimit = max(1, globalLimit)
        self.perOriginLimit = max(1, perOriginLimit)
    }

    func updateLimits(global: Int, perOrigin: Int) {
        globalLimit = max(1, global)
        perOriginLimit = max(1, perOrigin)
        admitWaiters()
    }

    func withPermit<Value: Sendable>(
        origin: Origin,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(origin: origin)
        defer { release(origin: origin) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(origin: Origin) async throws {
        try Task.checkCancellation()
        if canAdmit(origin) {
            recordAdmission(origin)
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, origin: origin, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func release(origin: Origin) {
        activeGlobal = max(0, activeGlobal - 1)
        let remaining = max(0, activeByOrigin[origin, default: 0] - 1)
        if remaining == 0 {
            activeByOrigin.removeValue(forKey: origin)
        } else {
            activeByOrigin[origin] = remaining
        }
        admitWaiters()
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func admitWaiters() {
        var index = 0
        while index < waiters.count, activeGlobal < globalLimit {
            let waiter = waiters[index]
            guard canAdmit(waiter.origin) else {
                index += 1
                continue
            }
            waiters.remove(at: index)
            recordAdmission(waiter.origin)
            waiter.continuation.resume()
        }
    }

    private func canAdmit(_ origin: Origin) -> Bool {
        activeGlobal < globalLimit
            && activeByOrigin[origin, default: 0] < perOriginLimit
    }

    private func recordAdmission(_ origin: Origin) {
        activeGlobal += 1
        activeByOrigin[origin, default: 0] += 1
    }
}
