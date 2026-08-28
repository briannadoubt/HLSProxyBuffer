import Foundation
import HLSCore

/// A validated, workload-level policy for automatic HLS playback.
///
/// Feed policies compose the existing player, cache, network, and retry
/// primitives into a small set of named experiences. Customize a preset by
/// replacing focused policy groups with ``Overrides``.
public struct FeedPlaybackPolicy: Sendable, Equatable {
    public enum Preset: String, CaseIterable, Sendable {
        case shortFormFeed
        case pagedFeed
        case continuousWindowedFeed
        case longForm
        case live
        case offlineFirst
    }

    /// Predictive item residency and leading-segment buffer targets.
    public struct PrefetchPolicy: Sendable, Equatable {
        public var aheadItemCount: Int
        public var behindItemCount: Int
        public var maximumLeadingSegments: Int
        public var focusedBufferSeconds: TimeInterval
        public var warmBufferSeconds: TimeInterval

        /// Viewports per second at which navigation direction begins to affect
        /// preparation order, and at which it becomes a strong directional bias.
        public var directionalVelocityThreshold: Double
        public var fastVelocityThreshold: Double

        public init(
            aheadItemCount: Int,
            behindItemCount: Int,
            maximumLeadingSegments: Int,
            focusedBufferSeconds: TimeInterval,
            warmBufferSeconds: TimeInterval,
            directionalVelocityThreshold: Double = 0.25,
            fastVelocityThreshold: Double = 2
        ) {
            self.aheadItemCount = aheadItemCount
            self.behindItemCount = behindItemCount
            self.maximumLeadingSegments = maximumLeadingSegments
            self.focusedBufferSeconds = focusedBufferSeconds
            self.warmBufferSeconds = warmBufferSeconds
            self.directionalVelocityThreshold = directionalVelocityThreshold
            self.fastVelocityThreshold = fastVelocityThreshold
        }
    }

    /// Hard item, preparation, and cache storage budgets.
    public struct BudgetPolicy: Sendable, Equatable {
        public var maximumResidentItems: Int
        public var maximumEstimatedPreparationBytes: Int
        public var memoryCacheBytes: Int
        public var diskCacheBytes: Int
        public var maximumCacheEntryCount: Int

        public init(
            maximumResidentItems: Int,
            maximumEstimatedPreparationBytes: Int,
            memoryCacheBytes: Int,
            diskCacheBytes: Int,
            maximumCacheEntryCount: Int
        ) {
            self.maximumResidentItems = maximumResidentItems
            self.maximumEstimatedPreparationBytes = maximumEstimatedPreparationBytes
            self.memoryCacheBytes = memoryCacheBytes
            self.diskCacheBytes = diskCacheBytes
            self.maximumCacheEntryCount = maximumCacheEntryCount
        }
    }

    /// Structured-task, origin-fetch, and player-pool limits.
    public struct ConcurrencyPolicy: Sendable, Equatable {
        public var maximumConcurrentPreparations: Int
        public var maximumConcurrentFetches: Int
        public var maximumPlayerCount: Int

        public init(
            maximumConcurrentPreparations: Int,
            maximumConcurrentFetches: Int,
            maximumPlayerCount: Int
        ) {
            self.maximumConcurrentPreparations = maximumConcurrentPreparations
            self.maximumConcurrentFetches = maximumConcurrentFetches
            self.maximumPlayerCount = maximumPlayerCount
        }
    }

    /// Cache lifetime and offscreen resource-retention behavior.
    public struct EvictionPolicy: Sendable, Equatable {
        public var usesDiskCache: Bool
        public var diskDirectory: URL?
        public var timeToLive: TimeInterval?
        public var offscreenGracePeriod: TimeInterval

        public init(
            usesDiskCache: Bool,
            diskDirectory: URL? = nil,
            timeToLive: TimeInterval?,
            offscreenGracePeriod: TimeInterval
        ) {
            self.usesDiskCache = usesDiskCache
            self.diskDirectory = diskDirectory
            self.timeToLive = timeToLive
            self.offscreenGracePeriod = offscreenGracePeriod
        }
    }

    /// Existing manifest and segment retry primitives as one override group.
    public struct RetryPolicy: Sendable, Equatable {
        public var manifest: HLSManifestFetcher.RetryPolicy
        public var segment: HLSSegmentFetcher.RetryPolicy

        public init(
            manifest: HLSManifestFetcher.RetryPolicy,
            segment: HLSSegmentFetcher.RetryPolicy
        ) {
            self.manifest = manifest
            self.segment = segment
        }
    }

    /// Automatic playback behavior at an item or collection boundary.
    public enum LoopingPolicy: String, CaseIterable, Sendable {
        case disabled
        case focusedItem
        case orderedCollection
    }

    /// Caps applied when the host reports low-power mode.
    ///
    /// Every cap retains at least one focused preparation, fetch, and player.
    public struct LowPowerPolicy: Sendable, Equatable {
        public var maximumPrefetchItems: Int
        public var maximumLeadingSegments: Int
        public var maximumConcurrentPreparations: Int
        public var maximumConcurrentFetches: Int
        public var maximumPlayerCount: Int

        public init(
            maximumPrefetchItems: Int,
            maximumLeadingSegments: Int,
            maximumConcurrentPreparations: Int,
            maximumConcurrentFetches: Int,
            maximumPlayerCount: Int
        ) {
            self.maximumPrefetchItems = maximumPrefetchItems
            self.maximumLeadingSegments = maximumLeadingSegments
            self.maximumConcurrentPreparations = maximumConcurrentPreparations
            self.maximumConcurrentFetches = maximumConcurrentFetches
            self.maximumPlayerCount = maximumPlayerCount
        }
    }

    /// Group-level replacements. A `nil` group inherits the current value.
    public struct Overrides: Sendable, Equatable {
        public var prefetch: PrefetchPolicy?
        public var budget: BudgetPolicy?
        public var concurrency: ConcurrencyPolicy?
        public var eviction: EvictionPolicy?
        public var network: HLSOriginNetworkPolicy?
        public var retry: RetryPolicy?
        public var looping: LoopingPolicy?
        public var lowPower: LowPowerPolicy?

        public init(
            prefetch: PrefetchPolicy? = nil,
            budget: BudgetPolicy? = nil,
            concurrency: ConcurrencyPolicy? = nil,
            eviction: EvictionPolicy? = nil,
            network: HLSOriginNetworkPolicy? = nil,
            retry: RetryPolicy? = nil,
            looping: LoopingPolicy? = nil,
            lowPower: LowPowerPolicy? = nil
        ) {
            self.prefetch = prefetch
            self.budget = budget
            self.concurrency = concurrency
            self.eviction = eviction
            self.network = network
            self.retry = retry
            self.looping = looping
            self.lowPower = lowPower
        }
    }

    public enum ValidationIssue: String, CaseIterable, Sendable {
        case prefetchItemCountsMustBeNonnegative
        case velocityThresholdsAreInvalid
        case leadingSegmentCountMustBePositive
        case bufferDurationsAreInvalid
        case residentItemBudgetIsInvalid
        case preparationByteBudgetMustBePositive
        case cacheBudgetsMustBeNonnegative
        case cacheEntryLimitMustBePositive
        case diskCacheRequiresCapacity
        case cacheTTLIsInvalid
        case offscreenGracePeriodIsInvalid
        case concurrencyLimitsMustBePositive
        case lowPowerLimitsAreInvalid
        case underlyingPlayerConfigurationIsInvalid
    }

    public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
        public let issues: [ValidationIssue]

        public init(issues: [ValidationIssue]) {
            self.issues = issues
        }

        public var errorDescription: String? {
            "Invalid feed playback policy: " + issues.map(\.rawValue).joined(separator: ", ")
        }
    }

    public let workload: Preset
    public let playerConfigurationPreset: ProxyPlayerConfiguration.Preset
    public var prefetch: PrefetchPolicy
    public var budget: BudgetPolicy
    public var concurrency: ConcurrencyPolicy
    public var eviction: EvictionPolicy
    public var network: HLSOriginNetworkPolicy
    public var retry: RetryPolicy
    public var looping: LoopingPolicy
    public var lowPower: LowPowerPolicy

    public init(
        workload: Preset,
        playerConfigurationPreset: ProxyPlayerConfiguration.Preset,
        prefetch: PrefetchPolicy,
        budget: BudgetPolicy,
        concurrency: ConcurrencyPolicy,
        eviction: EvictionPolicy,
        network: HLSOriginNetworkPolicy,
        retry: RetryPolicy,
        looping: LoopingPolicy,
        lowPower: LowPowerPolicy
    ) {
        self.workload = workload
        self.playerConfigurationPreset = playerConfigurationPreset
        self.prefetch = prefetch
        self.budget = budget
        self.concurrency = concurrency
        self.eviction = eviction
        self.network = network
        self.retry = retry
        self.looping = looping
        self.lowPower = lowPower
    }

    /// Returns an internally coherent starting point for a feed workload.
    public static func preset(_ preset: Preset) -> Self {
        let policy: Self
        switch preset {
        case .shortFormFeed:
            policy = makePolicy(
                workload: preset,
                playerPreset: .highThroughput,
                prefetch: .init(
                    aheadItemCount: 2,
                    behindItemCount: 2,
                    maximumLeadingSegments: 2,
                    focusedBufferSeconds: 4,
                    warmBufferSeconds: 2
                ),
                budget: .init(
                    maximumResidentItems: 5,
                    maximumEstimatedPreparationBytes: 96 * mebibyte,
                    memoryCacheBytes: 64 * mebibyte,
                    diskCacheBytes: 512 * mebibyte,
                    maximumCacheEntryCount: 4_096
                ),
                concurrency: .init(
                    maximumConcurrentPreparations: 3,
                    maximumConcurrentFetches: 6,
                    maximumPlayerCount: 3
                ),
                eviction: .init(
                    usesDiskCache: true,
                    timeToLive: 600,
                    offscreenGracePeriod: 0.25
                ),
                looping: .focusedItem,
                lowPower: .init(
                    maximumPrefetchItems: 1,
                    maximumLeadingSegments: 1,
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 2,
                    maximumPlayerCount: 2
                )
            )
        case .pagedFeed:
            policy = makePolicy(
                workload: preset,
                playerPreset: .highThroughput,
                prefetch: .init(
                    aheadItemCount: 1,
                    behindItemCount: 1,
                    maximumLeadingSegments: 3,
                    focusedBufferSeconds: 6,
                    warmBufferSeconds: 3
                ),
                budget: .init(
                    maximumResidentItems: 3,
                    maximumEstimatedPreparationBytes: 96 * mebibyte,
                    memoryCacheBytes: 64 * mebibyte,
                    diskCacheBytes: 512 * mebibyte,
                    maximumCacheEntryCount: 4_096
                ),
                concurrency: .init(
                    maximumConcurrentPreparations: 3,
                    maximumConcurrentFetches: 6,
                    maximumPlayerCount: 3
                ),
                eviction: .init(
                    usesDiskCache: true,
                    timeToLive: 900,
                    offscreenGracePeriod: 0.5
                ),
                looping: .disabled,
                lowPower: .init(
                    maximumPrefetchItems: 1,
                    maximumLeadingSegments: 1,
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 2,
                    maximumPlayerCount: 2
                )
            )
        case .continuousWindowedFeed:
            policy = makePolicy(
                workload: preset,
                playerPreset: .highThroughput,
                prefetch: .init(
                    aheadItemCount: 3,
                    behindItemCount: 1,
                    maximumLeadingSegments: 2,
                    focusedBufferSeconds: 5,
                    warmBufferSeconds: 2
                ),
                budget: .init(
                    maximumResidentItems: 5,
                    maximumEstimatedPreparationBytes: 128 * mebibyte,
                    memoryCacheBytes: 96 * mebibyte,
                    diskCacheBytes: 768 * mebibyte,
                    maximumCacheEntryCount: 6_144
                ),
                concurrency: .init(
                    maximumConcurrentPreparations: 4,
                    maximumConcurrentFetches: 8,
                    maximumPlayerCount: 4
                ),
                eviction: .init(
                    usesDiskCache: true,
                    timeToLive: 600,
                    offscreenGracePeriod: 0.2
                ),
                looping: .disabled,
                lowPower: .init(
                    maximumPrefetchItems: 1,
                    maximumLeadingSegments: 1,
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 2,
                    maximumPlayerCount: 2
                )
            )
        case .longForm:
            policy = makePolicy(
                workload: preset,
                playerPreset: .videoOnDemand,
                prefetch: .init(
                    aheadItemCount: 0,
                    behindItemCount: 0,
                    maximumLeadingSegments: 12,
                    focusedBufferSeconds: 30,
                    warmBufferSeconds: 0
                ),
                budget: .init(
                    maximumResidentItems: 1,
                    maximumEstimatedPreparationBytes: 256 * mebibyte,
                    memoryCacheBytes: 64 * mebibyte,
                    diskCacheBytes: 2 * gibibyte,
                    maximumCacheEntryCount: 8_192
                ),
                concurrency: .init(
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 6,
                    maximumPlayerCount: 1
                ),
                eviction: .init(
                    usesDiskCache: true,
                    timeToLive: nil,
                    offscreenGracePeriod: 0
                ),
                looping: .disabled,
                lowPower: .init(
                    maximumPrefetchItems: 0,
                    maximumLeadingSegments: 4,
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 2,
                    maximumPlayerCount: 1
                )
            )
        case .live:
            policy = makePolicy(
                workload: preset,
                playerPreset: .lowLatencyLive,
                prefetch: .init(
                    aheadItemCount: 1,
                    behindItemCount: 0,
                    maximumLeadingSegments: 3,
                    focusedBufferSeconds: 2,
                    warmBufferSeconds: 1
                ),
                budget: .init(
                    maximumResidentItems: 2,
                    maximumEstimatedPreparationBytes: 48 * mebibyte,
                    memoryCacheBytes: 24 * mebibyte,
                    diskCacheBytes: 0,
                    maximumCacheEntryCount: 2_048
                ),
                concurrency: .init(
                    maximumConcurrentPreparations: 2,
                    maximumConcurrentFetches: 4,
                    maximumPlayerCount: 2
                ),
                eviction: .init(
                    usesDiskCache: false,
                    timeToLive: 30,
                    offscreenGracePeriod: 0.1
                ),
                looping: .disabled,
                lowPower: .init(
                    maximumPrefetchItems: 0,
                    maximumLeadingSegments: 1,
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 2,
                    maximumPlayerCount: 1
                )
            )
        case .offlineFirst:
            policy = makePolicy(
                workload: preset,
                playerPreset: .videoOnDemand,
                prefetch: .init(
                    aheadItemCount: 2,
                    behindItemCount: 1,
                    maximumLeadingSegments: 6,
                    focusedBufferSeconds: 12,
                    warmBufferSeconds: 6
                ),
                budget: .init(
                    maximumResidentItems: 4,
                    maximumEstimatedPreparationBytes: 192 * mebibyte,
                    memoryCacheBytes: 96 * mebibyte,
                    diskCacheBytes: 4 * gibibyte,
                    maximumCacheEntryCount: 16_384
                ),
                concurrency: .init(
                    maximumConcurrentPreparations: 3,
                    maximumConcurrentFetches: 4,
                    maximumPlayerCount: 3
                ),
                eviction: .init(
                    usesDiskCache: true,
                    timeToLive: nil,
                    offscreenGracePeriod: 1
                ),
                network: .init(
                    requestTimeout: 30,
                    resourceTimeout: 180,
                    waitsForConnectivity: true,
                    allowsConstrainedNetworkAccess: true,
                    allowsExpensiveNetworkAccess: false,
                    maximumConnectionsPerHost: 4
                ),
                looping: .focusedItem,
                lowPower: .init(
                    maximumPrefetchItems: 0,
                    maximumLeadingSegments: 2,
                    maximumConcurrentPreparations: 1,
                    maximumConcurrentFetches: 1,
                    maximumPlayerCount: 1
                )
            )
        }
        assert(policy.validationIssues.isEmpty)
        return policy
    }

    public static var shortFormFeed: Self { preset(.shortFormFeed) }
    public static var pagedFeed: Self { preset(.pagedFeed) }
    public static var continuousWindowedFeed: Self { preset(.continuousWindowedFeed) }
    public static var longForm: Self { preset(.longForm) }
    public static var live: Self { preset(.live) }
    public static var offlineFirst: Self { preset(.offlineFirst) }

    /// Applies one group-level replacement and validates the result.
    public func applying(_ overrides: Overrides) throws -> Self {
        var result = self
        if let prefetch = overrides.prefetch { result.prefetch = prefetch }
        if let budget = overrides.budget { result.budget = budget }
        if let concurrency = overrides.concurrency { result.concurrency = concurrency }
        if let eviction = overrides.eviction { result.eviction = eviction }
        if let network = overrides.network { result.network = network }
        if let retry = overrides.retry { result.retry = retry }
        if let looping = overrides.looping { result.looping = looping }
        if let lowPower = overrides.lowPower { result.lowPower = lowPower }
        return try result.validated()
    }

    /// Applies replacements from first to last. A later non-`nil` group wins.
    public func applying(_ overrides: [Overrides]) throws -> Self {
        try overrides.reduce(self) { policy, replacement in
            try policy.applying(replacement)
        }
    }

    /// Returns the low-power effective policy without changing the focused item.
    public func adaptedForLowPowerMode(_ isEnabled: Bool) throws -> Self {
        guard isEnabled else { return try validated() }
        try validate()

        var result = self
        var remainingPrefetch = lowPower.maximumPrefetchItems
        result.prefetch.aheadItemCount = min(prefetch.aheadItemCount, remainingPrefetch)
        remainingPrefetch -= result.prefetch.aheadItemCount
        result.prefetch.behindItemCount = min(prefetch.behindItemCount, remainingPrefetch)
        result.prefetch.maximumLeadingSegments = lowPower.maximumLeadingSegments
        result.budget.maximumResidentItems = min(
            budget.maximumResidentItems,
            1 + lowPower.maximumPrefetchItems
        )
        result.concurrency.maximumConcurrentPreparations = lowPower.maximumConcurrentPreparations
        result.concurrency.maximumConcurrentFetches = lowPower.maximumConcurrentFetches
        result.concurrency.maximumPlayerCount = lowPower.maximumPlayerCount
        return try result.validated()
    }

    /// Builds the pure-planner limits used by the feed coordinator.
    public func makePlanningLimits() throws -> FeedPlanningLimits {
        try validate()
        let prefetchItemCount = prefetch.aheadItemCount + prefetch.behindItemCount
        return FeedPlanningLimits(
            maximumResidentItems: budget.maximumResidentItems,
            maximumPrefetchItems: prefetchItemCount,
            maximumConcurrentPreparations: concurrency.maximumConcurrentPreparations,
            maximumEstimatedPreparationBytes: budget.maximumEstimatedPreparationBytes,
            neighborPredictionHorizon: max(prefetch.aheadItemCount, prefetch.behindItemCount),
            maximumAheadItems: prefetch.aheadItemCount,
            maximumBehindItems: prefetch.behindItemCount,
            directionalVelocityThreshold: prefetch.directionalVelocityThreshold,
            fastVelocityThreshold: prefetch.fastVelocityThreshold,
            cancellationDeadline: .milliseconds(100)
        )
    }

    /// Maps the feed policy onto the existing validated player primitives.
    public func makeProxyPlayerConfiguration() throws -> ProxyPlayerConfiguration {
        try validate()
        return derivedPlayerConfiguration
    }

    /// All invariant violations in stable group order.
    public var validationIssues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func record(_ issue: ValidationIssue, when condition: Bool) {
            if condition, !issues.contains(issue) { issues.append(issue) }
        }

        let (prefetchItemCount, prefetchOverflow) = prefetch.aheadItemCount.addingReportingOverflow(
            prefetch.behindItemCount
        )
        record(
            .prefetchItemCountsMustBeNonnegative,
            when: prefetch.aheadItemCount < 0 || prefetch.behindItemCount < 0 || prefetchOverflow
        )
        record(
            .velocityThresholdsAreInvalid,
            when: !prefetch.directionalVelocityThreshold.isFinite
                || prefetch.directionalVelocityThreshold < 0
                || !prefetch.fastVelocityThreshold.isFinite
                || prefetch.fastVelocityThreshold < prefetch.directionalVelocityThreshold
        )
        record(.leadingSegmentCountMustBePositive, when: prefetch.maximumLeadingSegments < 1)
        record(
            .bufferDurationsAreInvalid,
            when: !prefetch.focusedBufferSeconds.isFinite
                || prefetch.focusedBufferSeconds <= 0
                || !prefetch.warmBufferSeconds.isFinite
                || prefetch.warmBufferSeconds < 0
                || prefetch.warmBufferSeconds > prefetch.focusedBufferSeconds
        )

        let (requiredResidentItems, residentOverflow) = prefetchItemCount.addingReportingOverflow(1)
        record(
            .residentItemBudgetIsInvalid,
            when: prefetchOverflow
                || residentOverflow
                || budget.maximumResidentItems < requiredResidentItems
        )
        record(
            .preparationByteBudgetMustBePositive,
            when: budget.maximumEstimatedPreparationBytes < 1
        )
        record(
            .cacheBudgetsMustBeNonnegative,
            when: budget.memoryCacheBytes < 0 || budget.diskCacheBytes < 0
        )
        record(.cacheEntryLimitMustBePositive, when: budget.maximumCacheEntryCount < 1)
        record(
            .diskCacheRequiresCapacity,
            when: eviction.usesDiskCache && budget.diskCacheBytes < 1
        )
        if let timeToLive = eviction.timeToLive {
            record(.cacheTTLIsInvalid, when: !timeToLive.isFinite || timeToLive < 0)
        }
        record(
            .offscreenGracePeriodIsInvalid,
            when: !eviction.offscreenGracePeriod.isFinite || eviction.offscreenGracePeriod < 0
        )
        record(
            .concurrencyLimitsMustBePositive,
            when: concurrency.maximumConcurrentPreparations < 1
                || concurrency.maximumConcurrentFetches < 1
                || concurrency.maximumPlayerCount < 1
        )

        let lowPowerIsInvalid = lowPower.maximumPrefetchItems < 0
            || lowPower.maximumPrefetchItems > prefetchItemCount
            || lowPower.maximumLeadingSegments < 1
            || lowPower.maximumLeadingSegments > prefetch.maximumLeadingSegments
            || lowPower.maximumConcurrentPreparations < 1
            || lowPower.maximumConcurrentPreparations > concurrency.maximumConcurrentPreparations
            || lowPower.maximumConcurrentFetches < 1
            || lowPower.maximumConcurrentFetches > concurrency.maximumConcurrentFetches
            || lowPower.maximumPlayerCount < 1
            || lowPower.maximumPlayerCount > concurrency.maximumPlayerCount
        record(.lowPowerLimitsAreInvalid, when: lowPowerIsInvalid)

        record(
            .underlyingPlayerConfigurationIsInvalid,
            when: !derivedPlayerConfiguration.validationIssues.isEmpty
        )
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

private extension FeedPlaybackPolicy {
    static let mebibyte = 1_024 * 1_024
    static let gibibyte = 1_024 * mebibyte

    static func makePolicy(
        workload: Preset,
        playerPreset: ProxyPlayerConfiguration.Preset,
        prefetch: PrefetchPolicy,
        budget: BudgetPolicy,
        concurrency: ConcurrencyPolicy,
        eviction: EvictionPolicy,
        network: HLSOriginNetworkPolicy? = nil,
        looping: LoopingPolicy,
        lowPower: LowPowerPolicy
    ) -> Self {
        let base = ProxyPlayerConfiguration.preset(playerPreset)
        return Self(
            workload: workload,
            playerConfigurationPreset: playerPreset,
            prefetch: prefetch,
            budget: budget,
            concurrency: concurrency,
            eviction: eviction,
            network: network ?? base.networkPolicy,
            retry: .init(
                manifest: base.manifestRetryPolicy,
                segment: base.segmentRetryPolicy
            ),
            looping: looping,
            lowPower: lowPower
        )
    }

    var derivedPlayerConfiguration: ProxyPlayerConfiguration {
        var configuration = ProxyPlayerConfiguration.preset(playerConfigurationPreset)
        configuration.bufferPolicy.targetBufferSeconds = prefetch.focusedBufferSeconds
        configuration.bufferPolicy.maxPrefetchSegments = prefetch.maximumLeadingSegments
        configuration.cachePolicy = .init(
            memoryCapacityBytes: budget.memoryCacheBytes,
            diskCapacityBytes: budget.diskCacheBytes,
            enableDiskCache: eviction.usesDiskCache,
            diskDirectory: eviction.diskDirectory,
            timeToLive: eviction.timeToLive,
            maximumEntryCount: budget.maximumCacheEntryCount
        )
        configuration.networkPolicy = network
        configuration.manifestRetryPolicy = retry.manifest
        configuration.segmentRetryPolicy = retry.segment
        return configuration
    }
}
