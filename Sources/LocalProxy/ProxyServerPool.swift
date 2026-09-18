import Foundation
import os

/// Shares one loopback listener while keeping each playback session's routes private.
/// The owner should retain the pool across clip turnover. Each lease has a fresh URL
/// namespace; closing it cancels its handlers without stopping sibling sessions.
public actor ProxyServerPool {
    public enum Error: Swift.Error { case capacityExceeded }

    private let registry: ProxyRouteRegistry
    private let server: ProxyServer
    private var startup: Task<URL, any Swift.Error>?
    private var startupGeneration: UInt64 = 0

    public init(maximumSessions: Int = 16, configuration: ProxyServer.Configuration = .init()) {
        let registry = ProxyRouteRegistry(maximumSessions: max(1, maximumSessions))
        self.registry = registry
        server = ProxyServer(configuration: configuration, router: ProxyRouter { request in
            await registry.handle(request)
        })
    }

    deinit {
        startup?.cancel()
        server.stop()
    }

    /// Cancellation of one reservation does not cancel another caller's listener startup.
    public func reserve(router: ProxyRouter) async throws -> ProxyServerLease {
        try Task.checkCancellation()
        if startup == nil {
            let server = server
            startupGeneration &+= 1
            startup = Task { try await server.startAndWait() }
        }
        guard let startup else { throw ProxyServerError.networkingUnavailable }
        let generation = startupGeneration
        let baseURL: URL
        do {
            baseURL = try await startup.value
        } catch {
            if generation == startupGeneration { self.startup = nil }
            throw error
        }
        try Task.checkCancellation()
        let id = UUID().uuidString.lowercased()
        router.freeze()
        let route = ProxySessionRoute(router: router)
        guard registry.insert(route, id: id) else { throw Error.capacityExceeded }
        return ProxyServerLease(baseURL: baseURL.appendingPathComponent(id), id: id,
                                registry: registry, route: route, owner: self)
    }
}

/// A private route namespace on a shared listener. Release or close it when playback ends.
public final class ProxyServerLease: Sendable {
    public let baseURL: URL
    private let id: String
    private let registry: ProxyRouteRegistry
    private let route: ProxySessionRoute
    // Keep the listener alive even if its original owner releases the pool.
    private let owner: ProxyServerPool

    fileprivate init(baseURL: URL, id: String, registry: ProxyRouteRegistry,
                     route: ProxySessionRoute, owner: ProxyServerPool) {
        self.baseURL = baseURL
        self.id = id
        self.registry = registry
        self.route = route
        self.owner = owner
    }

    deinit {
        registry.remove(id)
        route.cancel()
    }

    /// Rejects new requests and cancels only this lease's active route handlers.
    /// Bytes already handed to the shared connection may finish sending.
    public func close() {
        registry.remove(id)
        route.cancel()
    }

    /// Also waits for cooperative route cancellation before returning.
    public func closeAndWait() async {
        registry.remove(id)
        let tasks = route.cancel()
        for task in tasks { _ = await task.value }
    }
}

private final class ProxyRouteRegistry: Sendable {
    private let maximumSessions: Int
    private let routes = OSAllocatedUnfairLock(initialState: [String: ProxySessionRoute]())

    init(maximumSessions: Int) { self.maximumSessions = maximumSessions }

    func insert(_ route: ProxySessionRoute, id: String) -> Bool {
        routes.withLock {
            guard $0.count < maximumSessions else { return false }
            $0[id] = route
            return true
        }
    }

    func remove(_ id: String) { routes.withLock { _ = $0.removeValue(forKey: id) } }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path.hasPrefix("/") else { return HTTPResponse(status: .notFound) }
        let path = request.path.dropFirst()
        guard let slash = path.firstIndex(of: "/") else { return HTTPResponse(status: .notFound) }
        let id = String(path[..<slash])
        guard let route = routes.withLock({ $0[id] }) else { return HTTPResponse(status: .notFound) }
        return await route.handle(HTTPRequest(method: request.method, path: String(path[slash...]),
                                             queryItems: request.queryItems, version: request.version,
                                             headers: request.headers, body: request.body))
    }
}

private final class ProxySessionRoute: Sendable {
    private struct State {
        var closed = false
        var tasks: [UUID: Task<HTTPResponse, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let router: ProxyRouter

    init(router: ProxyRouter) { self.router = router }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let id = UUID()
        let router = router
        let task = state.withLock { state -> Task<HTTPResponse, Never>? in
            guard !state.closed else { return nil }
            let task = Task {
                guard !Task.isCancelled else { return HTTPResponse(status: .serviceUnavailable) }
                return await router.handle(request)
            }
            state.tasks[id] = task
            return task
        }
        guard let task else { return HTTPResponse(status: .notFound) }
        defer { state.withLock { _ = $0.tasks.removeValue(forKey: id) } }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func cancel() -> [Task<HTTPResponse, Never>] {
        let tasks = state.withLock { state in
            state.closed = true
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
        return tasks
    }
}
