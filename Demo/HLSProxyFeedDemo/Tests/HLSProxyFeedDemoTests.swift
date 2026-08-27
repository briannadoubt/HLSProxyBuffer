import Foundation
import XCTest
@testable import HLSProxyFeedDemo
import ProxyPlayerKit

@MainActor
final class HLSProxyFeedDemoTests: XCTestCase {
    func testEveryModeUsesAValidatedPolicyAndLocalFixtureCatalog() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }

        for mode in FeedDemoMode.allCases {
            let entries = FeedDemoCatalog.entries(for: mode, baseURL: baseURL)
            XCTAssertFalse(entries.isEmpty, "\(mode) must have a runnable fixture catalog")
            XCTAssertNoThrow(try mode.policy.validated())
            XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)

            let engine = try HLSFeedEngine(
                items: entries.map(\.item),
                policy: mode.policy,
                sourceTransportPolicy: .allowLoopbackHTTP
            )
            let first = try XCTUnwrap(entries.first)
            let initial = try await engine.update(FeedViewportSignal(
                generation: .init(rawValue: 1),
                focusedItemID: first.id,
                visibleItems: [.init(
                    itemID: first.id,
                    fraction: 1,
                    distanceInViewports: 0
                )],
                observedAt: .zero
            ))
            XCTAssertEqual(initial.targetFocusedItemID, first.id, "\(mode)")
            XCTAssertTrue(initial.failures.isEmpty, "\(mode): \(initial.failures)")
            await engine.stop()
        }
    }

    func testFixtureOriginServesByteRangesAndValidators() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let url = baseURL
            .appendingPathComponent("short-a", isDirectory: true)
            .appendingPathComponent("segment-000.m4s")
        var request = URLRequest(url: url)
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data.count, 32)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertNotNil(http.value(forHTTPHeaderField: "ETag"))
    }

    func testGeometrySignalsChooseFocusDeterministicallyAndPredictDirection() throws {
        let itemIDs: [FeedItemID] = ["a", "b", "c"]
        var builder = FeedDemoSignalBuilder(orderedItemIDs: itemIDs)
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let initial = try XCTUnwrap(builder.makeSignal(
            frames: [
                itemIDs[0]: CGRect(x: 0, y: 0, width: 100, height: 100),
                itemIDs[1]: CGRect(x: 0, y: 100, width: 100, height: 100),
            ],
            viewport: viewport,
            observedAt: .zero
        ))
        XCTAssertEqual(initial.focusedItemID, itemIDs[0])
        XCTAssertEqual(initial.generation.rawValue, 1)

        let advanced = try XCTUnwrap(builder.makeSignal(
            frames: [
                itemIDs[0]: CGRect(x: 0, y: -60, width: 100, height: 100),
                itemIDs[1]: CGRect(x: 0, y: 40, width: 100, height: 100),
                itemIDs[2]: CGRect(x: 0, y: 140, width: 100, height: 100),
            ],
            viewport: viewport,
            observedAt: .milliseconds(100)
        ))
        XCTAssertEqual(advanced.focusedItemID, itemIDs[1])
        XCTAssertEqual(advanced.generation.rawValue, 2)
        XCTAssertGreaterThan(advanced.velocityInViewportsPerSecond, 0)
        XCTAssertEqual(advanced.predictedDestinations.first?.itemID, itemIDs[2])
    }
}
