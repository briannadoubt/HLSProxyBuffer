import Foundation
import HLSCore

public struct ProxyPlayerConfiguration: Sendable, Equatable {
    public struct BufferPolicy: Sendable, Equatable {
        public var targetBufferSeconds: TimeInterval
        public var maxPrefetchSegments: Int
        public var hideUntilBuffered: Bool

        public init(
            targetBufferSeconds: TimeInterval = 6,
            maxPrefetchSegments: Int = 6,
            hideUntilBuffered: Bool = false
        ) {
            self.targetBufferSeconds = targetBufferSeconds
            self.maxPrefetchSegments = maxPrefetchSegments
            self.hideUntilBuffered = hideUntilBuffered
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

    public var qualityPolicy: HLSRewriteConfiguration.QualityPolicy
    public var bufferPolicy: BufferPolicy
    public var cachePolicy: CachePolicy
    public var lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions?
    public var manifestRetryPolicy: HLSManifestFetcher.RetryPolicy
    public var segmentValidation: HLSSegmentFetcher.ValidationPolicy
    public var upcomingPlaylists: [MediaPlaylist]
    public var allowInsecureManifests: Bool

    public init(
        qualityPolicy: HLSRewriteConfiguration.QualityPolicy = .automatic,
        bufferPolicy: BufferPolicy = .init(),
        cachePolicy: CachePolicy = .init(),
        lowLatencyOptions: HLSRewriteConfiguration.LowLatencyOptions? = nil,
        manifestRetryPolicy: HLSManifestFetcher.RetryPolicy = .default,
        segmentValidation: HLSSegmentFetcher.ValidationPolicy = .init(),
        upcomingPlaylists: [MediaPlaylist] = [],
        allowInsecureManifests: Bool = false
    ) {
        self.qualityPolicy = qualityPolicy
        self.bufferPolicy = bufferPolicy
        self.cachePolicy = cachePolicy
        self.lowLatencyOptions = lowLatencyOptions
        self.manifestRetryPolicy = manifestRetryPolicy
        self.segmentValidation = segmentValidation
        self.upcomingPlaylists = upcomingPlaylists
        self.allowInsecureManifests = allowInsecureManifests
    }
}
