#if canImport(Observation) && canImport(AVFoundation) && canImport(Network)
import XCTest
import Observation
import AVFoundation
import Network
@testable import ProxyPlayerKit
@testable import HLSCore
@testable import LocalProxy

@MainActor
final class ProxyPlayerKitObservationTests: XCTestCase {
    func testStateChangesTriggerObservationCallbacks() async throws {
        let origin = try MockOriginServer()
        try await origin.start()
        defer { origin.stop() }

        let configuration = ProxyPlayerConfiguration(allowInsecureManifests: true)
        let player = ProxyHLSPlayer(configuration: configuration)
        let expectation = expectation(description: "Observation fired")

        withObservationTracking {
            _ = player.state.status
        } onChange: {
            expectation.fulfill()
        }

        await player.load(from: origin.manifestURL, quality: .automatic)
        await fulfillment(of: [expectation], timeout: 5)
        player.stop()
    }
}
#endif
