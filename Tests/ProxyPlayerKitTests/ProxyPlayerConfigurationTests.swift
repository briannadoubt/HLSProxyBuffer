import XCTest
@testable import ProxyPlayerKit
@testable import HLSCore

final class ProxyPlayerConfigurationTests: XCTestCase {
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
