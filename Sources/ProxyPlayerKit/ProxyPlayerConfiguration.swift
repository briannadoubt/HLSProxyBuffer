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
        public var memoryCapacity: Int
        public var enableDiskCache: Bool
        public var diskDirectory: URL?

        public init(
            memoryCapacity: Int = 32,
            enableDiskCache: Bool = false,
            diskDirectory: URL? = nil
        ) {
            self.memoryCapacity = memoryCapacity
            self.enableDiskCache = enableDiskCache
            self.diskDirectory = diskDirectory
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

    public var qualityPolicy: HLSRewriteConfiguration.QualityPolicy
    public var bufferPolicy: BufferPolicy
    public var cachePolicy: CachePolicy
    public var abrPolicy: ABRPolicy
    public var lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions?
    public var manifestRetryPolicy: HLSManifestFetcher.RetryPolicy
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
        manifestRetryPolicy: HLSManifestFetcher.RetryPolicy = .default,
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
        self.manifestRetryPolicy = manifestRetryPolicy
        self.segmentValidation = segmentValidation
        self.upcomingPlaylists = upcomingPlaylists
        self.allowInsecureManifests = allowInsecureManifests
        self.drmPolicy = drmPolicy
    }
}
