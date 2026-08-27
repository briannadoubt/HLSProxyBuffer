import XCTest
@testable import ProxyPlayerKit
@testable import HLSCore

final class ProxyPlayerConfigurationTests: XCTestCase {
    func testEveryPresetPassesPublicValidation() throws {
        for preset in ProxyPlayerConfiguration.Preset.allCases {
            let configuration = ProxyPlayerConfiguration.preset(preset)
            XCTAssertTrue(configuration.validationIssues.isEmpty, preset.rawValue)
            XCTAssertNoThrow(try configuration.validate(), preset.rawValue)
            XCTAssertEqual(try configuration.validated(), configuration)
        }
    }

    func testPresetWorkloadInvariants() throws {
        let lowBandwidth = ProxyPlayerConfiguration.preset(.lowBandwidth)
        XCTAssertEqual(lowBandwidth.networkPolicy.maximumConnectionsPerHost, 2)
        XCTAssertEqual(lowBandwidth.bufferPolicy.maxPrefetchSegments, 3)
        XCTAssertEqual(lowBandwidth.cachePolicy.memoryCapacityBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(lowBandwidth.cachePolicy.timeToLive, 90)
        XCTAssertGreaterThanOrEqual(lowBandwidth.abrPolicy.maximumBitrateRatio, 1.5)

        let highThroughput = ProxyPlayerConfiguration.preset(.highThroughput)
        XCTAssertEqual(highThroughput.networkPolicy.maximumConnectionsPerHost, 12)
        XCTAssertGreaterThanOrEqual(highThroughput.bufferPolicy.targetBufferSeconds, 20)
        XCTAssertGreaterThanOrEqual(highThroughput.bufferPolicy.maxPrefetchSegments, 12)
        XCTAssertEqual(highThroughput.cachePolicy.memoryCapacityBytes, 128 * 1_024 * 1_024)

        let live = ProxyPlayerConfiguration.preset(.lowLatencyLive)
        XCTAssertTrue(live.lowLatencyPolicy.isEnabled)
        XCTAssertTrue(live.lowLatencyPolicy.enableBlockingReloads)
        XCTAssertTrue(try XCTUnwrap(live.lowLatencyOptions).allowBlockingReload)
        XCTAssertTrue(try XCTUnwrap(live.lowLatencyOptions).enableDeltaUpdates)
        XCTAssertLessThanOrEqual(live.bufferPolicy.targetBufferSeconds, 2)
        XCTAssertFalse(live.cachePolicy.enableDiskCache)

        let vod = ProxyPlayerConfiguration.preset(.videoOnDemand)
        XCTAssertTrue(vod.bufferPolicy.hideUntilBuffered)
        XCTAssertGreaterThanOrEqual(vod.bufferPolicy.targetBufferSeconds, 30)
        XCTAssertTrue(vod.cachePolicy.enableDiskCache)
        XCTAssertNil(vod.cachePolicy.timeToLive)
        XCTAssertFalse(vod.lowLatencyPolicy.isEnabled)
        XCTAssertNil(vod.lowLatencyOptions)
    }

    func testValidationReportsMutatedPolicyViolations() throws {
        var configuration = ProxyPlayerConfiguration()
        configuration.bufferPolicy.targetBufferSeconds = 0
        configuration.bufferPolicy.maxPrefetchSegments = 0
        configuration.bufferPolicy.refreshInterval = -1
        configuration.bufferPolicy.maxRefreshBackoff = -2
        configuration.cachePolicy.memoryCapacityBytes = -1
        configuration.cachePolicy.enableDiskCache = true
        configuration.cachePolicy.diskCapacityBytes = 0
        configuration.cachePolicy.timeToLive = .nan
        configuration.cachePolicy.maximumEntryCount = 0
        configuration.abrPolicy.estimatorWindow = 0
        configuration.abrPolicy.minimumBitrateRatio = 0
        configuration.abrPolicy.maximumBitrateRatio = .infinity
        configuration.abrPolicy.hysteresisPercent = 100
        configuration.abrPolicy.minimumSwitchInterval = -.infinity
        configuration.abrPolicy.failureDowngradeThreshold = 0
        configuration.lowLatencyPolicy = .init(
            isEnabled: true,
            targetPartBufferCount: 0,
            enableBlockingReloads: true,
            blockingRequestTimeout: 0
        )

        let expected: Set<ProxyPlayerConfiguration.ValidationIssue> = [
            .targetBufferMustBePositive,
            .prefetchSegmentCountMustBePositive,
            .refreshIntervalMustBePositive,
            .refreshBackoffMustCoverInterval,
            .cacheCapacityMustBeNonnegative,
            .enabledDiskCacheRequiresCapacity,
            .cacheTTLIsInvalid,
            .cacheEntryLimitMustBePositive,
            .abrEstimatorWindowMustBePositive,
            .abrRatiosMustBePositive,
            .abrHysteresisIsInvalid,
            .abrSwitchIntervalIsInvalid,
            .abrFailureThresholdMustBePositive,
            .partBufferCountIsInvalid,
            .blockingReloadTimeoutMustBePositive,
            .lowLatencyPoliciesAreInconsistent
        ]
        XCTAssertEqual(Set(configuration.validationIssues), expected)
        XCTAssertThrowsError(try configuration.validated()) { error in
            guard let validationError = error as? ProxyPlayerConfiguration.ValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(Set(validationError.issues), expected)
            XCTAssertTrue(validationError.localizedDescription.contains("targetBufferMustBePositive"))
        }
    }

    func testValidationRejectsInconsistentLowLatencyRewriteOptions() {
        var configuration = ProxyPlayerConfiguration()
        configuration.lowLatencyOptions = .init(
            canSkipUntil: -1,
            partHoldBack: 0,
            allowBlockingReload: true,
            prefetchHintCount: -1,
            enableDeltaUpdates: true
        )

        XCTAssertEqual(
            Set(configuration.validationIssues),
            [.lowLatencyPoliciesAreInconsistent, .lowLatencyOptionsAreInvalid]
        )
    }

    func testStoresOriginNetworkPolicy() {
        let policy = HLSOriginNetworkPolicy(
            requestTimeout: 8,
            resourceTimeout: 24,
            waitsForConnectivity: true,
            allowsConstrainedNetworkAccess: false,
            allowsExpensiveNetworkAccess: false,
            maximumConnectionsPerHost: 2
        )

        let configuration = ProxyPlayerConfiguration(networkPolicy: policy)

        XCTAssertEqual(configuration.networkPolicy, policy)
    }

    func testStoresSegmentRetryPolicy() {
        let policy = HLSSegmentFetcher.RetryPolicy(
            maxAttempts: 5,
            initialDelay: 0.5,
            multiplier: 1.5,
            maximumDelay: 4,
            jitterRatio: 0.1,
            maximumRetryAfter: 20
        )

        let configuration = ProxyPlayerConfiguration(segmentRetryPolicy: policy)

        XCTAssertEqual(configuration.segmentRetryPolicy, policy)
    }

    func testCachePolicyNormalizesTTLAndMetadataBound() {
        let immediate = ProxyPlayerConfiguration.CachePolicy(
            timeToLive: -5,
            maximumEntryCount: 0
        )
        XCTAssertEqual(immediate.timeToLive, 0)
        XCTAssertEqual(immediate.maximumEntryCount, 1)

        let disabled = ProxyPlayerConfiguration.CachePolicy(timeToLive: .infinity)
        XCTAssertNil(disabled.timeToLive)
    }
}
