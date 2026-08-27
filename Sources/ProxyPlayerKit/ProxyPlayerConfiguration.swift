import Foundation
import HLSCore

public struct ProxyPlayerConfiguration: Sendable, Equatable {
    public enum DRMPolicy: Sendable, Equatable {
        case passthrough
        case proxy
    }

    public struct BufferPolicy: Sendable, Equatable {
        public var targetBufferSeconds: TimeInterval
        public var maxPrefetchSegments: Int
        public var hideUntilBuffered: Bool
        public var refreshInterval: TimeInterval
        public var maxRefreshBackoff: TimeInterval

        public init(
            targetBufferSeconds: TimeInterval = 6,
            maxPrefetchSegments: Int = 6,
            hideUntilBuffered: Bool = false,
            refreshInterval: TimeInterval = 2,
            maxRefreshBackoff: TimeInterval = 8
        ) {
            self.targetBufferSeconds = targetBufferSeconds
            self.maxPrefetchSegments = maxPrefetchSegments
            self.hideUntilBuffered = hideUntilBuffered
            self.refreshInterval = refreshInterval
            self.maxRefreshBackoff = maxRefreshBackoff
        }
    }

    public struct CachePolicy: Sendable, Equatable {
        public var memoryCapacityBytes: Int
        public var diskCapacityBytes: Int
        public var enableDiskCache: Bool
        public var diskDirectory: URL?
        /// Optional entry lifetime. `nil` keeps entries until LRU eviction.
        public var timeToLive: TimeInterval?
        /// Bounds metadata independently of byte budgets, including zero-byte entries.
        public var maximumEntryCount: Int

        public init(
            memoryCapacityBytes: Int = 32 * 1024 * 1024,
            diskCapacityBytes: Int = 512 * 1024 * 1024,
            enableDiskCache: Bool = false,
            diskDirectory: URL? = nil,
            timeToLive: TimeInterval? = nil,
            maximumEntryCount: Int = 4_096
        ) {
            self.memoryCapacityBytes = max(0, memoryCapacityBytes)
            self.diskCapacityBytes = max(0, diskCapacityBytes)
            self.enableDiskCache = enableDiskCache
            self.diskDirectory = diskDirectory
            self.timeToLive = timeToLive.flatMap { $0.isFinite ? max(0, $0) : nil }
            self.maximumEntryCount = max(1, maximumEntryCount)
        }

        @available(*, deprecated, message: "Use memoryCapacityBytes; the value is a byte budget.")
        public init(
            memoryCapacity: Int,
            enableDiskCache: Bool = false,
            diskDirectory: URL? = nil
        ) {
            self.init(
                memoryCapacityBytes: memoryCapacity,
                enableDiskCache: enableDiskCache,
                diskDirectory: diskDirectory
            )
        }

        @available(*, deprecated, message: "Use memoryCapacityBytes; the value is a byte budget.")
        public var memoryCapacity: Int {
            get { memoryCapacityBytes }
            set { memoryCapacityBytes = max(0, newValue) }
        }
    }

    public struct ABRPolicy: Sendable, Equatable {
        public var isEnabled: Bool
        public var estimatorWindow: Int
        public var minimumBitrateRatio: Double
        public var maximumBitrateRatio: Double
        public var hysteresisPercent: Double
        public var minimumSwitchInterval: TimeInterval
        public var failureDowngradeThreshold: Int

        public init(
            isEnabled: Bool = true,
            estimatorWindow: Int = 5,
            minimumBitrateRatio: Double = 0.85,
            maximumBitrateRatio: Double = 1.2,
            hysteresisPercent: Double = 10,
            minimumSwitchInterval: TimeInterval = 4,
            failureDowngradeThreshold: Int = 2
        ) {
            self.isEnabled = isEnabled
            self.estimatorWindow = estimatorWindow
            self.minimumBitrateRatio = minimumBitrateRatio
            self.maximumBitrateRatio = maximumBitrateRatio
            self.hysteresisPercent = hysteresisPercent
            self.minimumSwitchInterval = minimumSwitchInterval
            self.failureDowngradeThreshold = failureDowngradeThreshold
        }
    }

    public struct LowLatencyPolicy: Sendable, Equatable {
        public var isEnabled: Bool
        public var targetPartBufferCount: Int
        public var enableBlockingReloads: Bool
        public var blockingRequestTimeout: TimeInterval

        public init(
            isEnabled: Bool = false,
            targetPartBufferCount: Int = 0,
            enableBlockingReloads: Bool = false,
            blockingRequestTimeout: TimeInterval = 6
        ) {
            self.isEnabled = isEnabled
            self.targetPartBufferCount = targetPartBufferCount
            self.enableBlockingReloads = enableBlockingReloads
            self.blockingRequestTimeout = blockingRequestTimeout
        }
    }

    public var qualityPolicy: HLSRewriteConfiguration.QualityPolicy
    public var bufferPolicy: BufferPolicy
    public var cachePolicy: CachePolicy
    public var abrPolicy: ABRPolicy
    public var lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions?
    public var lowLatencyPolicy: LowLatencyPolicy
    public var networkPolicy: HLSOriginNetworkPolicy
    public var manifestRetryPolicy: HLSManifestFetcher.RetryPolicy
    public var segmentRetryPolicy: HLSSegmentFetcher.RetryPolicy
    public var segmentValidation: HLSSegmentFetcher.ValidationPolicy
    public var upcomingPlaylists: [MediaPlaylist]
    public var allowInsecureManifests: Bool
    public var drmPolicy: DRMPolicy

    public init(
        qualityPolicy: HLSRewriteConfiguration.QualityPolicy = .automatic,
        bufferPolicy: BufferPolicy = .init(),
        cachePolicy: CachePolicy = .init(),
        abrPolicy: ABRPolicy = .init(),
        lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions? = nil,
        lowLatencyPolicy: LowLatencyPolicy = .init(),
        networkPolicy: HLSOriginNetworkPolicy = .default,
        manifestRetryPolicy: HLSManifestFetcher.RetryPolicy = .default,
        segmentRetryPolicy: HLSSegmentFetcher.RetryPolicy = .default,
        segmentValidation: HLSSegmentFetcher.ValidationPolicy = .init(),
        upcomingPlaylists: [MediaPlaylist] = [],
        allowInsecureManifests: Bool = false,
        drmPolicy: DRMPolicy = .passthrough
    ) {
        self.qualityPolicy = qualityPolicy
        self.bufferPolicy = bufferPolicy
        self.cachePolicy = cachePolicy
        self.abrPolicy = abrPolicy
        self.lowLatencyOptions = lowLatencyOptions
        self.lowLatencyPolicy = lowLatencyPolicy
        self.networkPolicy = networkPolicy
        self.manifestRetryPolicy = manifestRetryPolicy
        self.segmentRetryPolicy = segmentRetryPolicy
        self.segmentValidation = segmentValidation
        self.upcomingPlaylists = upcomingPlaylists
        self.allowInsecureManifests = allowInsecureManifests
        self.drmPolicy = drmPolicy
    }
}
