import Foundation
import HLSCore

public struct ProxyPlayerConfiguration: Sendable, Equatable {
    /// Opinionated starting points. Tune the returned value using production telemetry.
    public enum Preset: String, CaseIterable, Sendable {
        case lowBandwidth
        case highThroughput
        case lowLatencyLive
        case videoOnDemand
    }

    public enum ValidationIssue: String, CaseIterable, Sendable {
        case targetBufferMustBePositive
        case prefetchSegmentCountMustBePositive
        case refreshIntervalMustBePositive
        case refreshBackoffMustCoverInterval
        case cacheCapacityMustBeNonnegative
        case enabledDiskCacheRequiresCapacity
        case cacheTTLIsInvalid
        case cacheEntryLimitMustBePositive
        case abrEstimatorWindowMustBePositive
        case abrRatiosMustBePositive
        case abrHysteresisIsInvalid
        case abrSwitchIntervalIsInvalid
        case abrFailureThresholdMustBePositive
        case partBufferCountIsInvalid
        case blockingReloadTimeoutMustBePositive
        case lowLatencyPoliciesAreInconsistent
        case lowLatencyOptionsAreInvalid
    }

    public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
        public let issues: [ValidationIssue]

        public init(issues: [ValidationIssue]) {
            self.issues = issues
        }

        public var errorDescription: String? {
            "Invalid proxy player configuration: "
                + issues.map(\.rawValue).joined(separator: ", ")
        }
    }

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

    /// Returns one internally coherent starting point for a common workload.
    public static func preset(_ preset: Preset) -> Self {
        let configuration: Self
        switch preset {
        case .lowBandwidth:
            configuration = Self(
                bufferPolicy: .init(
                    targetBufferSeconds: 5,
                    maxPrefetchSegments: 3,
                    refreshInterval: 3,
                    maxRefreshBackoff: 12
                ),
                cachePolicy: .init(
                    memoryCapacityBytes: 8 * 1_024 * 1_024,
                    diskCapacityBytes: 64 * 1_024 * 1_024,
                    timeToLive: 90,
                    maximumEntryCount: 1_024
                ),
                abrPolicy: .init(
                    estimatorWindow: 7,
                    minimumBitrateRatio: 0.95,
                    maximumBitrateRatio: 1.5,
                    hysteresisPercent: 15,
                    minimumSwitchInterval: 8,
                    failureDowngradeThreshold: 1
                ),
                networkPolicy: .init(
                    requestTimeout: 30,
                    resourceTimeout: 90,
                    waitsForConnectivity: true,
                    maximumConnectionsPerHost: 2
                ),
                manifestRetryPolicy: .init(
                    maxAttempts: 4,
                    retryDelay: 0.5,
                    maximumRetryDelay: 8,
                    jitterRatio: 0.2
                ),
                segmentRetryPolicy: .init(
                    maxAttempts: 4,
                    initialDelay: 0.5,
                    multiplier: 2,
                    maximumDelay: 8,
                    jitterRatio: 0.2,
                    maximumRetryAfter: 60
                )
            )
        case .highThroughput:
            configuration = Self(
                bufferPolicy: .init(
                    targetBufferSeconds: 20,
                    maxPrefetchSegments: 12,
                    refreshInterval: 2,
                    maxRefreshBackoff: 8
                ),
                cachePolicy: .init(
                    memoryCapacityBytes: 128 * 1_024 * 1_024,
                    diskCapacityBytes: 1_024 * 1_024 * 1_024,
                    maximumEntryCount: 8_192
                ),
                abrPolicy: .init(
                    estimatorWindow: 3,
                    minimumBitrateRatio: 0.85,
                    maximumBitrateRatio: 1.1,
                    hysteresisPercent: 8,
                    minimumSwitchInterval: 2,
                    failureDowngradeThreshold: 2
                ),
                networkPolicy: .init(
                    requestTimeout: 12,
                    resourceTimeout: 60,
                    maximumConnectionsPerHost: 12
                ),
                segmentRetryPolicy: .init(
                    maxAttempts: 3,
                    initialDelay: 0.15,
                    multiplier: 2,
                    maximumDelay: 3,
                    jitterRatio: 0.15,
                    maximumRetryAfter: 30
                )
            )
        case .lowLatencyLive:
            configuration = Self(
                bufferPolicy: .init(
                    targetBufferSeconds: 2,
                    maxPrefetchSegments: 3,
                    refreshInterval: 0.5,
                    maxRefreshBackoff: 2
                ),
                cachePolicy: .init(
                    memoryCapacityBytes: 16 * 1_024 * 1_024,
                    diskCapacityBytes: 64 * 1_024 * 1_024,
                    timeToLive: 30,
                    maximumEntryCount: 2_048
                ),
                abrPolicy: .init(
                    estimatorWindow: 3,
                    minimumBitrateRatio: 0.95,
                    maximumBitrateRatio: 1.35,
                    hysteresisPercent: 12,
                    minimumSwitchInterval: 2,
                    failureDowngradeThreshold: 1
                ),
                lowLatencyOptions: .init(
                    partHoldBack: 1.5,
                    allowBlockingReload: true,
                    prefetchHintCount: 2,
                    enableDeltaUpdates: true
                ),
                lowLatencyPolicy: .init(
                    isEnabled: true,
                    targetPartBufferCount: 3,
                    enableBlockingReloads: true,
                    blockingRequestTimeout: 5
                ),
                networkPolicy: .init(
                    requestTimeout: 8,
                    resourceTimeout: 30,
                    waitsForConnectivity: true,
                    maximumConnectionsPerHost: 6
                ),
                manifestRetryPolicy: .init(
                    maxAttempts: 5,
                    retryDelay: 0.15,
                    maximumRetryDelay: 2,
                    jitterRatio: 0.15
                ),
                segmentRetryPolicy: .init(
                    maxAttempts: 3,
                    initialDelay: 0.1,
                    multiplier: 2,
                    maximumDelay: 1,
                    jitterRatio: 0.1,
                    maximumRetryAfter: 5
                )
            )
        case .videoOnDemand:
            configuration = Self(
                bufferPolicy: .init(
                    targetBufferSeconds: 30,
                    maxPrefetchSegments: 12,
                    hideUntilBuffered: true,
                    refreshInterval: 5,
                    maxRefreshBackoff: 20
                ),
                cachePolicy: .init(
                    memoryCapacityBytes: 64 * 1_024 * 1_024,
                    diskCapacityBytes: 2 * 1_024 * 1_024 * 1_024,
                    enableDiskCache: true,
                    maximumEntryCount: 8_192
                ),
                abrPolicy: .init(
                    estimatorWindow: 8,
                    minimumBitrateRatio: 0.85,
                    maximumBitrateRatio: 1.15,
                    hysteresisPercent: 10,
                    minimumSwitchInterval: 6,
                    failureDowngradeThreshold: 2
                ),
                networkPolicy: .init(
                    requestTimeout: 20,
                    resourceTimeout: 120,
                    maximumConnectionsPerHost: 8
                )
            )
        }
        assert(configuration.validationIssues.isEmpty)
        return configuration
    }

    /// All invariant violations, in stable policy order.
    public var validationIssues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func record(_ issue: ValidationIssue, when condition: Bool) {
            if condition, !issues.contains(issue) { issues.append(issue) }
        }

        record(
            .targetBufferMustBePositive,
            when: !bufferPolicy.targetBufferSeconds.isFinite
                || bufferPolicy.targetBufferSeconds <= 0
        )
        record(.prefetchSegmentCountMustBePositive, when: bufferPolicy.maxPrefetchSegments < 1)
        record(
            .refreshIntervalMustBePositive,
            when: !bufferPolicy.refreshInterval.isFinite || bufferPolicy.refreshInterval <= 0
        )
        record(
            .refreshBackoffMustCoverInterval,
            when: !bufferPolicy.maxRefreshBackoff.isFinite
                || bufferPolicy.maxRefreshBackoff < bufferPolicy.refreshInterval
        )

        record(
            .cacheCapacityMustBeNonnegative,
            when: cachePolicy.memoryCapacityBytes < 0 || cachePolicy.diskCapacityBytes < 0
        )
        record(
            .enabledDiskCacheRequiresCapacity,
            when: cachePolicy.enableDiskCache && cachePolicy.diskCapacityBytes == 0
        )
        if let timeToLive = cachePolicy.timeToLive {
            record(.cacheTTLIsInvalid, when: !timeToLive.isFinite || timeToLive < 0)
        }
        record(.cacheEntryLimitMustBePositive, when: cachePolicy.maximumEntryCount < 1)

        record(.abrEstimatorWindowMustBePositive, when: abrPolicy.estimatorWindow < 1)
        record(
            .abrRatiosMustBePositive,
            when: !abrPolicy.minimumBitrateRatio.isFinite
                || abrPolicy.minimumBitrateRatio <= 0
                || !abrPolicy.maximumBitrateRatio.isFinite
                || abrPolicy.maximumBitrateRatio <= 0
        )
        record(
            .abrHysteresisIsInvalid,
            when: !abrPolicy.hysteresisPercent.isFinite
                || abrPolicy.hysteresisPercent < 0
                || abrPolicy.hysteresisPercent >= 100
        )
        record(
            .abrSwitchIntervalIsInvalid,
            when: !abrPolicy.minimumSwitchInterval.isFinite
                || abrPolicy.minimumSwitchInterval < 0
        )
        record(
            .abrFailureThresholdMustBePositive,
            when: abrPolicy.failureDowngradeThreshold < 1
        )

        record(
            .partBufferCountIsInvalid,
            when: lowLatencyPolicy.targetPartBufferCount < 0
                || (lowLatencyPolicy.isEnabled && lowLatencyPolicy.targetPartBufferCount < 1)
        )
        record(
            .blockingReloadTimeoutMustBePositive,
            when: !lowLatencyPolicy.blockingRequestTimeout.isFinite
                || lowLatencyPolicy.blockingRequestTimeout <= 0
        )
        record(
            .lowLatencyPoliciesAreInconsistent,
            when: lowLatencyPolicy.isEnabled != (lowLatencyOptions != nil)
        )
        if let options = lowLatencyOptions {
            let blockingMismatch = options.allowBlockingReload
                != lowLatencyPolicy.enableBlockingReloads
            let invalidSkip = options.canSkipUntil.map { !$0.isFinite || $0 < 0 } ?? false
            let invalidHoldBack = options.partHoldBack.map { !$0.isFinite || $0 <= 0 } ?? false
            record(
                .lowLatencyPoliciesAreInconsistent,
                when: blockingMismatch || (lowLatencyPolicy.enableBlockingReloads && !lowLatencyPolicy.isEnabled)
            )
            record(
                .lowLatencyOptionsAreInvalid,
                when: invalidSkip || invalidHoldBack || options.prefetchHintCount < 0
            )
        } else {
            record(
                .lowLatencyPoliciesAreInconsistent,
                when: lowLatencyPolicy.enableBlockingReloads
            )
        }
        return issues
    }

    public func validate() throws {
        let issues = validationIssues
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
    }

    public func validated() throws -> Self {
        try validate()
        return self
    }
}
