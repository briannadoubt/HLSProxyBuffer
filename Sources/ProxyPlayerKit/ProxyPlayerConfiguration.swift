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

    public struct NetworkPolicy: Sendable, Equatable {
        public var segmentTimeout: TimeInterval
        public var manifestTimeout: TimeInterval
        public var enableHTTP2: Bool
        public var connectionKeepAlive: Bool
        public var maxConcurrentFetches: Int

        public init(
            segmentTimeout: TimeInterval = 20,
            manifestTimeout: TimeInterval = 10,
            enableHTTP2: Bool = true,
            connectionKeepAlive: Bool = true,
            maxConcurrentFetches: Int = 4
        ) {
            self.segmentTimeout = segmentTimeout
            self.manifestTimeout = manifestTimeout
            self.enableHTTP2 = enableHTTP2
            self.connectionKeepAlive = connectionKeepAlive
            self.maxConcurrentFetches = maxConcurrentFetches
        }
    }

    public struct RateLimitPolicy: Sendable, Equatable {
        public var isEnabled: Bool
        public var requestsPerSecond: Double
        public var burstCapacity: Int

        public init(
            isEnabled: Bool = false,
            requestsPerSecond: Double = 100,
            burstCapacity: Int = 20
        ) {
            self.isEnabled = isEnabled
            self.requestsPerSecond = requestsPerSecond
            self.burstCapacity = burstCapacity
        }
    }

    public var qualityPolicy: HLSRewriteConfiguration.QualityPolicy
    public var bufferPolicy: BufferPolicy
    public var cachePolicy: CachePolicy
    public var abrPolicy: ABRPolicy
    public var lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions?
    public var lowLatencyPolicy: LowLatencyPolicy
    public var networkPolicy: NetworkPolicy
    public var rateLimitPolicy: RateLimitPolicy
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
        lowLatencyPolicy: LowLatencyPolicy = .init(),
        networkPolicy: NetworkPolicy = .init(),
        rateLimitPolicy: RateLimitPolicy = .init(),
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
        self.lowLatencyPolicy = lowLatencyPolicy
        self.networkPolicy = networkPolicy
        self.rateLimitPolicy = rateLimitPolicy
        self.manifestRetryPolicy = manifestRetryPolicy
        self.segmentValidation = segmentValidation
        self.upcomingPlaylists = upcomingPlaylists
        self.allowInsecureManifests = allowInsecureManifests
        self.drmPolicy = drmPolicy
    }
}

// MARK: - Configuration Presets
public extension ProxyPlayerConfiguration {
    /// Preset optimized for low bandwidth connections (e.g., 3G, poor WiFi)
    static var lowBandwidth: ProxyPlayerConfiguration {
        ProxyPlayerConfiguration(
            bufferPolicy: BufferPolicy(
                targetBufferSeconds: 12,
                maxPrefetchSegments: 3,
                hideUntilBuffered: true,
                refreshInterval: 4,
                maxRefreshBackoff: 16
            ),
            cachePolicy: CachePolicy(
                memoryCapacity: 16,
                enableDiskCache: true
            ),
            abrPolicy: ABRPolicy(
                isEnabled: true,
                minimumBitrateRatio: 0.7,
                maximumBitrateRatio: 1.0,
                hysteresisPercent: 15,
                minimumSwitchInterval: 8,
                failureDowngradeThreshold: 1
            ),
            networkPolicy: NetworkPolicy(
                segmentTimeout: 30,
                manifestTimeout: 15,
                maxConcurrentFetches: 2
            )
        )
    }

    /// Preset optimized for high throughput connections (e.g., fiber, 5G)
    static var highThroughput: ProxyPlayerConfiguration {
        ProxyPlayerConfiguration(
            bufferPolicy: BufferPolicy(
                targetBufferSeconds: 4,
                maxPrefetchSegments: 8,
                hideUntilBuffered: false,
                refreshInterval: 1,
                maxRefreshBackoff: 4
            ),
            cachePolicy: CachePolicy(
                memoryCapacity: 64,
                enableDiskCache: false
            ),
            abrPolicy: ABRPolicy(
                isEnabled: true,
                minimumBitrateRatio: 0.9,
                maximumBitrateRatio: 1.5,
                hysteresisPercent: 5,
                minimumSwitchInterval: 2,
                failureDowngradeThreshold: 3
            ),
            networkPolicy: NetworkPolicy(
                segmentTimeout: 15,
                manifestTimeout: 8,
                maxConcurrentFetches: 6
            )
        )
    }

    /// Preset optimized for low-latency live streaming (LL-HLS)
    static var lowLatencyLive: ProxyPlayerConfiguration {
        ProxyPlayerConfiguration(
            bufferPolicy: BufferPolicy(
                targetBufferSeconds: 2,
                maxPrefetchSegments: 4,
                hideUntilBuffered: false,
                refreshInterval: 0.5,
                maxRefreshBackoff: 2
            ),
            cachePolicy: CachePolicy(
                memoryCapacity: 48,
                enableDiskCache: false
            ),
            abrPolicy: ABRPolicy(
                isEnabled: true,
                minimumBitrateRatio: 0.85,
                maximumBitrateRatio: 1.2,
                hysteresisPercent: 8,
                minimumSwitchInterval: 3,
                failureDowngradeThreshold: 2
            ),
            lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions(
                enablePreloadHints: true,
                enableRenditionReports: true,
                enableDeltaUpdates: true
            ),
            lowLatencyPolicy: LowLatencyPolicy(
                isEnabled: true,
                targetPartBufferCount: 3,
                enableBlockingReloads: true,
                blockingRequestTimeout: 4
            ),
            networkPolicy: NetworkPolicy(
                segmentTimeout: 10,
                manifestTimeout: 5,
                maxConcurrentFetches: 4
            )
        )
    }

    /// Preset for VOD playback with aggressive caching
    static var vodPlayback: ProxyPlayerConfiguration {
        ProxyPlayerConfiguration(
            bufferPolicy: BufferPolicy(
                targetBufferSeconds: 30,
                maxPrefetchSegments: 10,
                hideUntilBuffered: false,
                refreshInterval: 0,
                maxRefreshBackoff: 0
            ),
            cachePolicy: CachePolicy(
                memoryCapacity: 128,
                enableDiskCache: true
            ),
            abrPolicy: ABRPolicy(
                isEnabled: true,
                minimumBitrateRatio: 0.8,
                maximumBitrateRatio: 1.3,
                hysteresisPercent: 10,
                minimumSwitchInterval: 5,
                failureDowngradeThreshold: 2
            ),
            networkPolicy: NetworkPolicy(
                segmentTimeout: 30,
                manifestTimeout: 15,
                maxConcurrentFetches: 4
            )
        )
    }
}
