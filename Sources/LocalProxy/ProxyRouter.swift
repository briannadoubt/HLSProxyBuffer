import Foundation
import os

public final class ProxyRouter: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private struct Route: Sendable {
        let path: String
        let handler: Handler
    }

    private struct State: Sendable {
        var routes: [Route] = []
        var isFrozen = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fallback: Handler

    public init(fallback: @escaping Handler = { @Sendable _ in HTTPResponse(status: .notFound) }) {
        self.fallback = fallback
    }

    /// Registers a route before the server starts. Returns false after the router is frozen.
    @discardableResult
    public func register(path: String, handler: @escaping Handler) -> Bool {
        state.withLock { state in
            guard !state.isFrozen else { return false }
            state.routes.append(Route(path: path, handler: handler))
            return true
        }
    }

    func freeze() {
        state.withLock { $0.isFrozen = true }
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let handler = state.withLock { state -> Handler? in
            state.routes.first(where: { matches(path: $0.path, requestPath: request.path) })?.handler
        }
        return await (handler ?? fallback)(request)
    }

    private func matches(path: String, requestPath: String) -> Bool {
        if path.hasSuffix("*") {
            return requestPath.hasPrefix(String(path.dropLast()))
        }
        return path == requestPath
    }
}
