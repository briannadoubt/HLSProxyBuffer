import Foundation
import XCTest
@testable import HLSCore

final class HLSOriginNetworkPolicyTests: XCTestCase {
    func testBuildsConfigurationWithBoundedOriginSettings() {
        let policy = HLSOriginNetworkPolicy(
            requestTimeout: 7,
            resourceTimeout: 21,
            waitsForConnectivity: true,
            allowsConstrainedNetworkAccess: false,
            allowsExpensiveNetworkAccess: false,
            maximumConnectionsPerHost: 3
        )

        let configuration = policy.makeURLSessionConfiguration()

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 21)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 3)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
    }

    func testNormalizesInvalidTimeoutsAndConnectionLimit() {
        let policy = HLSOriginNetworkPolicy(
            requestTimeout: .nan,
            resourceTimeout: -1,
            maximumConnectionsPerHost: 0
        )

        XCTAssertEqual(policy.requestTimeout, 20)
        XCTAssertEqual(policy.resourceTimeout, 60)
        XCTAssertEqual(policy.maximumConnectionsPerHost, 1)
    }

    func testResourceTimeoutCannotBeShorterThanRequestTimeout() {
        let policy = HLSOriginNetworkPolicy(requestTimeout: 30, resourceTimeout: 10)

        XCTAssertEqual(policy.resourceTimeout, 30)
    }
}
