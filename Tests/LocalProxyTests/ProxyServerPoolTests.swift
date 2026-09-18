#if canImport(Network)
import Foundation
import XCTest
@testable import LocalProxy

final class ProxyServerPoolTests: XCTestCase {
    func testNamespacesShareListenerAndRetiredURLCannotReachReplacement() async throws {
        let pool = ProxyServerPool(maximumSessions: 2)
        let first = try await pool.reserve(router: router(body: "first"))
        let second = try await pool.reserve(router: router(body: "second"))
        XCTAssertEqual(first.baseURL.port, second.baseURL.port)
        XCTAssertNotEqual(first.baseURL.path, second.baseURL.path)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (lease, expected) in [(first, "first"), (second, "second")] {
            let (data, response) = try await session.data(from: lease.baseURL.appendingPathComponent("media"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), expected)
        }
        do {
            _ = try await pool.reserve(router: router(body: "overflow"))
            XCTFail("Pool must enforce admission limit")
        } catch ProxyServerPool.Error.capacityExceeded {} catch { throw error }
        await first.closeAndWait()
        let replacement = try await pool.reserve(router: router(body: "replacement"))
        XCTAssertEqual(replacement.baseURL.port, second.baseURL.port)
        XCTAssertNotEqual(replacement.baseURL.path, first.baseURL.path)
        let (_, retired) = try await session.data(from: first.baseURL.appendingPathComponent("media"))
        XCTAssertEqual((retired as? HTTPURLResponse)?.statusCode, 404)
        let (body, _) = try await session.data(from: second.baseURL.appendingPathComponent("media"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "second")
        await second.closeAndWait()
        await replacement.closeAndWait()
    }

    func testClosingLeaseCancelsItsHandlerAndPreservesSibling() async throws {
        let entered = expectation(description: "route started")
        let cancelled = expectation(description: "route cancelled")
        let slow = ProxyRouter()
        slow.register(path: "/media") { _ in
            entered.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
                return HTTPResponse(status: .internalServerError)
            } catch {
                cancelled.fulfill()
                return HTTPResponse(status: .serviceUnavailable)
            }
        }
        let pool = ProxyServerPool()
        let first = try await pool.reserve(router: slow)
        let second = try await pool.reserve(router: router(body: "sibling"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = Task { try await session.data(from: first.baseURL.appendingPathComponent("media")) }
        await fulfillment(of: [entered], timeout: 2)
        await first.closeAndWait()
        await fulfillment(of: [cancelled], timeout: 1)
        let (_, response) = try await request.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let (body, response2) = try await session.data(from: second.baseURL.appendingPathComponent("media"))
        XCTAssertEqual((response2 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "sibling")
        await second.closeAndWait()
    }

    func testConcurrentReservationsUseOneListenerAndCancelledAdmissionLeaksNoSlot() async throws {
        let pool = ProxyServerPool(maximumSessions: 4)
        let routes = (0..<4).map { router(body: "stream-\($0)") }
        let leases = try await withThrowingTaskGroup(of: ProxyServerLease.self) { group in
            for route in routes { group.addTask { try await pool.reserve(router: route) } }
            var leases: [ProxyServerLease] = []
            for try await lease in group { leases.append(lease) }
            return leases
        }
        XCTAssertEqual(Set(leases.map { $0.baseURL.port }).count, 1)
        XCTAssertEqual(Set(leases.map { $0.baseURL.path }).count, 4)
        for lease in leases { await lease.closeAndWait() }
        let cancelledRouter = router(body: "cancelled")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pool.reserve(router: cancelledRouter)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled admission must throw")
        } catch is CancellationError {} catch { throw error }
        let replacement = try await pool.reserve(router: router(body: "replacement"))
        XCTAssertEqual(replacement.baseURL.port, leases.first?.baseURL.port)
        await replacement.closeAndWait()
    }

    func testDroppingLeaseReturnsAdmissionAndRetiresItsNamespace() async throws {
        let pool = ProxyServerPool(maximumSessions: 1)
        var lease: ProxyServerLease? = try await pool.reserve(router: router(body: "retired"))
        let retiredURL = try XCTUnwrap(lease?.baseURL).appendingPathComponent("media")
        weak var released = lease
        lease = nil
        XCTAssertNil(released)
        let replacement = try await pool.reserve(router: router(body: "replacement"))
        let (_, response) = try await URLSession.shared.data(from: retiredURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        await replacement.closeAndWait()
    }

    private func router(body: String) -> ProxyRouter {
        let router = ProxyRouter()
        router.register(path: "/media") { _ in HTTPResponse(status: .ok, body: Data(body.utf8)) }
        return router
    }
}
#endif
