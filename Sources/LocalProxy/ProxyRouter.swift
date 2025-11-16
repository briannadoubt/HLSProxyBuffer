import Foundation

public final class ProxyRouter {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private var handlers: [(path: String, handler: Handler)] = []
    private let fallback: Handler

    public init(fallback: @escaping Handler = { @Sendable _ in HTTPResponse(status: .notFound) }) {
        self.fallback = fallback
    }

    public func register(path: String, handler: @escaping Handler) {
        handlers.append((path, handler))
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        for (path, handler) in handlers where matches(path: path, requestPath: request.path) {
            return await handler(request)
        }
        return await fallback(request)
    }

    private func matches(path: String, requestPath: String) -> Bool {
        if path.hasSuffix("*") {
            let prefix = String(path.dropLast())
            return requestPath.hasPrefix(prefix)
        }
        return path == requestPath
    }
}
