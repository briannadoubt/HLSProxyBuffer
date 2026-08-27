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
}
