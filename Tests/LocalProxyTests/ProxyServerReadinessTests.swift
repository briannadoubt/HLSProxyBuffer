#if canImport(Network)
import Foundation
import XCTest
@testable import LocalProxy

final class ProxyServerReadinessTests: XCTestCase {
    func testConcurrentWaitersReceiveTheBoundAddressAcrossRestarts() async throws {
        let server = ProxyServer(router: ProxyRouter())
        defer { server.stop() }
        for _ in 0..<10 {
            try server.start()
            let urls = try await withThrowingTaskGroup(of: URL.self) { group in
                for _ in 0..<8 { group.addTask { try await server.waitUntilReady() } }
                var values: [URL] = []
                for try await url in group { values.append(url) }
                return values
            }
            XCTAssertEqual(urls.count, 8)
            XCTAssertEqual(Set(urls).count, 1)
            XCTAssertEqual(urls.first, server.baseURL)
            server.stop()
        }
    }

    func testCancelledWaiterLeavesOtherCallersAndListenerUsable() async throws {
        let server = ProxyServer(router: ProxyRouter())
        defer { server.stop() }
        try server.start()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await server.waitUntilReady()
        }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled waiter must not succeed, even if the port is already ready")
        } catch is CancellationError {
            // Expected; cancelling a waiter must not stop the shared listener.
        }
        let url = try await server.waitUntilReady()
        XCTAssertEqual(url, server.baseURL)
    }

    func testStopRacingWithReadinessCompletesAndAllowsRestart() async throws {
        let server = ProxyServer(router: ProxyRouter())
        defer { server.stop() }
        for _ in 0..<30 {
            try server.start()
            let waiting = Task { try await server.waitUntilReady() }
            await Task.yield()
            server.stop()
            do {
                _ = try await waiting.value // Ready may win the race.
            } catch is CancellationError {
                // Stop may win the race; a timeout or another error is unexpected.
            }
            let url = try await server.startAndWait()
            XCTAssertEqual(url, server.baseURL)
            server.stop()
        }
    }

    func testWaitTimeoutDoesNotStopListenerButStartTimeoutCleansUp() async throws {
        let server = ProxyServer(router: ProxyRouter())
        defer { server.stop() }
        try server.start()
        do {
            _ = try await server.waitUntilReady(timeout: .zero)
            XCTFail("A zero timeout must fail")
        } catch ProxyServerError.startupTimedOut {
            // A non-owning waiter does not stop the listener.
        }
        _ = try await server.waitUntilReady()
        server.stop()
        do {
            _ = try await server.startAndWait(timeout: .zero)
            XCTFail("A zero startup timeout must fail")
        } catch ProxyServerError.startupTimedOut {
            XCTAssertNil(server.port)
        }
        _ = try await server.startAndWait()
    }

    func testTinyDeadlinesRaceReadinessWithoutStrandingOtherWaiters() async throws {
        let server = ProxyServer(router: ProxyRouter())
        defer { server.stop() }
        for _ in 0..<30 {
            try server.start()
            do {
                _ = try await server.waitUntilReady(timeout: .nanoseconds(1))
            } catch ProxyServerError.startupTimedOut {
                // Either readiness or the timer may win. The other child must drain.
            }
            let url = try await server.waitUntilReady()
            XCTAssertEqual(url, server.baseURL)
            server.stop()
        }
    }

    func testBindFailureIsPropagatedAndDoesNotAffectExistingListener() async throws {
        let first = ProxyServer(router: ProxyRouter())
        defer { first.stop() }
        let firstURL = try await first.startAndWait()
        let port = try XCTUnwrap(first.port)
        let conflicting = ProxyServer(configuration: .init(port: port), router: ProxyRouter())
        defer { conflicting.stop() }
        do {
            _ = try await conflicting.startAndWait()
            XCTFail("Two listeners must not own the same loopback port")
        } catch {
            XCTAssertNil(conflicting.port)
        }
        let stillReady = try await first.waitUntilReady()
        XCTAssertEqual(stillReady, firstURL)
    }
}
#endif
