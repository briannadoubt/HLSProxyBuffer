import Foundation
import LocalProxy
import XCTest
@testable import HLSProxyFeedDemo

@MainActor
final class FeedDemoBodyBudgetTests: XCTestCase {
    func testResponseCopiesRetainTheirPermitUntilTheFinalCopyIsReleased() async throws {
        let budget = FeedDemoBodyBudget(bodyLimit: 1, byteLimit: 1_024)
        var permit: FeedDemoBodyBudget.Permit? = try await budget.acquire(bytes: 32)
        weak var weakPermit = permit
        var original: HTTPResponse? = HTTPResponse(
            status: .ok,
            body: Data(repeating: 1, count: 32),
            onBodyRelease: { [heldPermit = permit] in withExtendedLifetime(heldPermit) {} }
        )
        permit = nil
        var copy = original
        original = nil
        withExtendedLifetime(copy) {
            XCTAssertNotNil(weakPermit)
            XCTAssertEqual(copy?.body.count, 32)
        }
        copy = nil
        XCTAssertNil(weakPermit)
        try await waitUntil { await budget.snapshot().activeBodyCount == 0 }
    }

    func testCancellationRemovesQueuedAdmissionWithoutReadingOrLeaking() async throws {
        let budget = FeedDemoBodyBudget(bodyLimit: 1, byteLimit: 1_024)
        var permit: FeedDemoBodyBudget.Permit? = try await budget.acquire(bytes: 32)
        let pending = Task { try await budget.acquire(bytes: 64) }
        try await waitUntil { await budget.snapshot().queuedCount == 1 }
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Cancelled admission should throw")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let state = await budget.snapshot()
        XCTAssertEqual(state.queuedCount, 0)
        XCTAssertEqual(state.activeBodyCount, 1)
        XCTAssertEqual(state.activeBodyBytes, 32)
        XCTAssertEqual(state.materializationCount, 0)
        XCTAssertEqual(state.cancellationCount, 1)
        withExtendedLifetime(permit) {}
        permit = nil
        try await waitUntil { await budget.snapshot().activeBodyCount == 0 }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
