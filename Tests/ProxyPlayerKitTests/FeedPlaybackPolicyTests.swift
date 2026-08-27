import XCTest
@testable import ProxyPlayerKit
import HLSCore

final class FeedPlaybackPolicyTests: XCTestCase {
    func testEveryPresetIsValidAndBuildsExistingConfiguration() throws {
        for preset in FeedPlaybackPolicy.Preset.allCases {
            let policy = FeedPlaybackPolicy.preset(preset)

            XCTAssertEqual(policy.workload, preset)
            XCTAssertTrue(policy.validationIssues.isEmpty, preset.rawValue)
            XCTAssertNoThrow(try policy.validate(), preset.rawValue)
            XCTAssertTrue(try policy.makeProxyPlayerConfiguration().validationIssues.isEmpty)
            XCTAssertGreaterThanOrEqual(try policy.makePlanningLimits().maximumResidentItems, 1)
        }
    }

    func testPresetWorkloadIntentIsExplicit() throws {
        let shortForm = FeedPlaybackPolicy.preset(.shortFormFeed)
        XCTAssertEqual(shortForm.looping, .focusedItem)
        XCTAssertEqual(shortForm.prefetch.aheadItemCount, 2)
        XCTAssertEqual(shortForm.concurrency.maximumPlayerCount, 3)

        let paged = FeedPlaybackPolicy.preset(.pagedFeed)
        XCTAssertEqual(paged.prefetch.aheadItemCount, 1)
        XCTAssertEqual(paged.prefetch.behindItemCount, 1)

        let continuous = FeedPlaybackPolicy.preset(.continuousWindowedFeed)
        XCTAssertGreaterThanOrEqual(continuous.prefetch.aheadItemCount, 3)
        XCTAssertGreaterThan(continuous.budget.maximumResidentItems, paged.budget.maximumResidentItems)

        let longForm = FeedPlaybackPolicy.preset(.longForm)
        XCTAssertEqual(try longForm.makePlanningLimits().maximumPrefetchItems, 0)
        XCTAssertEqual(longForm.concurrency.maximumPlayerCount, 1)
        XCTAssertTrue(longForm.eviction.usesDiskCache)

        let live = FeedPlaybackPolicy.preset(.live)
        XCTAssertTrue(try live.makeProxyPlayerConfiguration().lowLatencyPolicy.isEnabled)
        XCTAssertFalse(live.eviction.usesDiskCache)

        let offline = FeedPlaybackPolicy.preset(.offlineFirst)
        XCTAssertTrue(offline.eviction.usesDiskCache)
        XCTAssertFalse(offline.network.allowsExpensiveNetworkAccess)
        XCTAssertGreaterThanOrEqual(offline.budget.diskCacheBytes, 4 * gibibyte)
    }

    func testFocusedOverrideGroupsMapOntoExistingPrimitives() throws {
        let base = FeedPlaybackPolicy.preset(.pagedFeed)
        let prefetch = FeedPlaybackPolicy.PrefetchPolicy(
            aheadItemCount: 2,
            behindItemCount: 0,
            maximumLeadingSegments: 4,
            focusedBufferSeconds: 8,
            warmBufferSeconds: 3
        )
        let budget = FeedPlaybackPolicy.BudgetPolicy(
            maximumResidentItems: 3,
            maximumEstimatedPreparationBytes: 80 * mebibyte,
            memoryCacheBytes: 48 * mebibyte,
            diskCacheBytes: 256 * mebibyte,
            maximumCacheEntryCount: 2_048
        )
        let concurrency = FeedPlaybackPolicy.ConcurrencyPolicy(
            maximumConcurrentPreparations: 2,
            maximumConcurrentFetches: 3,
            maximumPlayerCount: 2
        )
        let eviction = FeedPlaybackPolicy.EvictionPolicy(
            usesDiskCache: true,
            diskDirectory: URL(fileURLWithPath: "/tmp/feed-policy-cache"),
            timeToLive: 120,
            offscreenGracePeriod: 0.75
        )
        let network = HLSOriginNetworkPolicy(
            requestTimeout: 9,
            resourceTimeout: 45,
            waitsForConnectivity: true,
            allowsConstrainedNetworkAccess: false,
            allowsExpensiveNetworkAccess: false,
            maximumConnectionsPerHost: 3
        )
        let retry = FeedPlaybackPolicy.RetryPolicy(
            manifest: .init(
                maxAttempts: 2,
                retryDelay: 0.1,
                maximumRetryDelay: 1,
                jitterRatio: 0
            ),
            segment: .init(
                maxAttempts: 2,
                initialDelay: 0.1,
                multiplier: 2,
                maximumDelay: 1,
                jitterRatio: 0,
                maximumRetryAfter: 2
            )
        )
        let lowPower = FeedPlaybackPolicy.LowPowerPolicy(
            maximumPrefetchItems: 1,
            maximumLeadingSegments: 2,
            maximumConcurrentPreparations: 1,
            maximumConcurrentFetches: 1,
            maximumPlayerCount: 1
        )

        let policy = try base.applying(.init(
            prefetch: prefetch,
            budget: budget,
            concurrency: concurrency,
            eviction: eviction,
            network: network,
            retry: retry,
            looping: .orderedCollection,
            lowPower: lowPower
        ))
        let configuration = try policy.makeProxyPlayerConfiguration()
        let planning = try policy.makePlanningLimits()

        XCTAssertEqual(policy.prefetch, prefetch)
        XCTAssertEqual(policy.budget, budget)
        XCTAssertEqual(policy.concurrency, concurrency)
        XCTAssertEqual(policy.eviction, eviction)
        XCTAssertEqual(policy.network, network)
        XCTAssertEqual(policy.retry, retry)
        XCTAssertEqual(policy.looping, .orderedCollection)
        XCTAssertEqual(policy.lowPower, lowPower)
        XCTAssertEqual(configuration.bufferPolicy.targetBufferSeconds, 8)
        XCTAssertEqual(configuration.bufferPolicy.maxPrefetchSegments, 4)
        XCTAssertEqual(configuration.cachePolicy.memoryCapacityBytes, 48 * mebibyte)
        XCTAssertEqual(configuration.cachePolicy.diskDirectory, eviction.diskDirectory)
        XCTAssertEqual(configuration.networkPolicy, network)
        XCTAssertEqual(configuration.segmentRetryPolicy, retry.segment)
        XCTAssertEqual(planning.maximumPrefetchItems, 2)
        XCTAssertEqual(planning.maximumConcurrentPreparations, 2)
    }

    func testLaterOverrideWinsOnlyForItsNonNilGroup() throws {
        let base = FeedPlaybackPolicy.preset(.shortFormFeed)
        var firstBudget = base.budget
        firstBudget.memoryCacheBytes = 40 * mebibyte
        var firstPrefetch = base.prefetch
        firstPrefetch.focusedBufferSeconds = 5
        var finalPrefetch = firstPrefetch
        finalPrefetch.focusedBufferSeconds = 7

        let result = try base.applying([
            .init(prefetch: firstPrefetch, budget: firstBudget),
            .init(looping: .disabled),
            .init(prefetch: finalPrefetch),
        ])

        XCTAssertEqual(result.prefetch, finalPrefetch)
        XCTAssertEqual(result.budget, firstBudget)
        XCTAssertEqual(result.looping, .disabled)
        XCTAssertEqual(result.network, base.network)
    }

    func testInvalidCombinationsReturnStableTypedDiagnostics() {
        var policy = FeedPlaybackPolicy.preset(.continuousWindowedFeed)
        policy.prefetch.aheadItemCount = -1
        policy.prefetch.maximumLeadingSegments = 0
        policy.prefetch.warmBufferSeconds = .infinity
        policy.budget.maximumResidentItems = 0
        policy.budget.maximumEstimatedPreparationBytes = 0
        policy.budget.memoryCacheBytes = -1
        policy.budget.maximumCacheEntryCount = 0
        policy.eviction.timeToLive = .nan
        policy.eviction.offscreenGracePeriod = -1
        policy.concurrency.maximumConcurrentPreparations = 0
        policy.lowPower.maximumPrefetchItems = 99

        let expected: Set<FeedPlaybackPolicy.ValidationIssue> = [
            .prefetchItemCountsMustBeNonnegative,
            .leadingSegmentCountMustBePositive,
            .bufferDurationsAreInvalid,
            .residentItemBudgetIsInvalid,
            .preparationByteBudgetMustBePositive,
            .cacheBudgetsMustBeNonnegative,
            .cacheEntryLimitMustBePositive,
            .cacheTTLIsInvalid,
            .offscreenGracePeriodIsInvalid,
            .concurrencyLimitsMustBePositive,
            .lowPowerLimitsAreInvalid,
            .underlyingPlayerConfigurationIsInvalid,
        ]

        XCTAssertEqual(Set(policy.validationIssues), expected)
        XCTAssertThrowsError(try policy.validated()) { error in
            guard let validationError = error as? FeedPlaybackPolicy.ValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(Set(validationError.issues), expected)
        }
    }

    func testInvalidOverrideFailsWithoutMutatingBaseValue() {
        let base = FeedPlaybackPolicy.preset(.pagedFeed)
        var invalidBudget = base.budget
        invalidBudget.maximumResidentItems = 1

        XCTAssertThrowsError(try base.applying(.init(budget: invalidBudget)))
        XCTAssertEqual(base, FeedPlaybackPolicy.preset(.pagedFeed))
    }

    func testLowPowerAdaptationReducesSpeculationAndKeepsFocus() throws {
        let base = FeedPlaybackPolicy.preset(.continuousWindowedFeed)
        let adapted = try base.adaptedForLowPowerMode(true)
        let items = makeItems(count: 8)
        let focusedID = items[3].id
        let signal = FeedViewportSignal(
            generation: .init(rawValue: 1),
            focusedItemID: focusedID,
            visibleItems: [.init(itemID: focusedID, fraction: 1, distanceInViewports: 0)],
            velocityInViewportsPerSecond: 4,
            observedAt: .zero
        )
        let basePlan = try FeedPlanner(limits: base.makePlanningLimits()).makePlan(
            items: items,
            signal: signal
        )
        let adaptedPlan = try FeedPlanner(limits: adapted.makePlanningLimits()).makePlan(
            items: items,
            signal: signal
        )

        XCTAssertLessThan(
            adapted.prefetch.aheadItemCount + adapted.prefetch.behindItemCount,
            base.prefetch.aheadItemCount + base.prefetch.behindItemCount
        )
        XCTAssertLessThan(
            adapted.concurrency.maximumConcurrentPreparations,
            base.concurrency.maximumConcurrentPreparations
        )
        XCTAssertLessThan(
            adapted.concurrency.maximumConcurrentFetches,
            base.concurrency.maximumConcurrentFetches
        )
        XCTAssertLessThan(
            adapted.concurrency.maximumPlayerCount,
            base.concurrency.maximumPlayerCount
        )
        XCTAssertLessThan(adaptedPlan.desiredEntries.count, basePlan.desiredEntries.count)
        XCTAssertEqual(adaptedPlan.desiredEntries.first?.itemID, focusedID)
        XCTAssertEqual(adaptedPlan.desiredEntries.first?.role, .focused)
    }

    func testDisablingLowPowerModeIsIdentity() throws {
        let policy = FeedPlaybackPolicy.preset(.offlineFirst)
        XCTAssertEqual(try policy.adaptedForLowPowerMode(false), policy)
    }

    func testPolicySurfaceIsSendableAndExistingPresetsRemainAvailable() {
        assertSendable(FeedPlaybackPolicy.preset(.shortFormFeed))
        assertSendable(FeedPlaybackPolicy.Overrides())
        assertSendable(FeedPlaybackPolicy.LowPowerPolicy(
            maximumPrefetchItems: 0,
            maximumLeadingSegments: 1,
            maximumConcurrentPreparations: 1,
            maximumConcurrentFetches: 1,
            maximumPlayerCount: 1
        ))
        XCTAssertEqual(
            Set(ProxyPlayerConfiguration.Preset.allCases),
            [.lowBandwidth, .highThroughput, .lowLatencyLive, .videoOnDemand]
        )
    }
}

private extension FeedPlaybackPolicyTests {
    var mebibyte: Int { 1_024 * 1_024 }
    var gibibyte: Int { 1_024 * mebibyte }

    func makeItems(count: Int) -> [FeedPlaybackItem] {
        (0..<count).map { index in
            FeedPlaybackItem(
                id: .init(rawValue: "item-\(index)"),
                source: .stream(
                    url: URL(fileURLWithPath: "/fixtures/item-\(index).m3u8"),
                    kind: .videoOnDemand
                ),
                estimatedPreparationBytes: 4 * mebibyte
            )
        }
    }

    func assertSendable<Value: Sendable>(_ value: Value) {
        _ = value
    }
}
