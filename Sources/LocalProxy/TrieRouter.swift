import Foundation

/// Trie-based router for efficient route matching
public actor TrieRouter {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private class TrieNode {
        var handlers: [HTTPMethod: Handler] = [:]
        var children: [String: TrieNode] = [:]
        var parameterChild: (name: String, node: TrieNode)?
        var wildcardHandler: Handler?
    }

    public enum HTTPMethod: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
        case head = "HEAD"
        case options = "OPTIONS"
    }

    public struct RouteMatch: Sendable {
        public let handler: Handler
        public let parameters: [String: String]
    }

    private let root = TrieNode()
    private var routeCount = 0

    public init() {}

    // MARK: - Route Registration

    public func register(
        _ method: HTTPMethod,
        path: String,
        handler: @escaping Handler
    ) {
        let components = pathComponents(from: path)
        var node = root

        for component in components {
            if component.hasPrefix(":") {
                // Parameter component
                let paramName = String(component.dropFirst())
                if node.parameterChild == nil {
                    node.parameterChild = (paramName, TrieNode())
                }
                node = node.parameterChild!.node
            } else if component == "*" {
                // Wildcard
                node.wildcardHandler = handler
                routeCount += 1
                return
            } else {
                // Static component
                if node.children[component] == nil {
                    node.children[component] = TrieNode()
                }
                node = node.children[component]!
            }
        }

        node.handlers[method] = handler
        routeCount += 1
    }

    public func get(_ path: String, handler: @escaping Handler) {
        register(.get, path: path, handler: handler)
    }

    public func post(_ path: String, handler: @escaping Handler) {
        register(.post, path: path, handler: handler)
    }

    // MARK: - Route Matching

    public func match(method: HTTPMethod, path: String) -> RouteMatch? {
        let components = pathComponents(from: path)
        var node = root
        var parameters: [String: String] = [:]

        for component in components {
            // Check static match first
            if let child = node.children[component] {
                node = child
                continue
            }

            // Check parameter match
            if let param = node.parameterChild {
                parameters[param.name] = component
                node = param.node
                continue
            }

            // Check wildcard
            if let wildcardHandler = node.wildcardHandler {
                return RouteMatch(handler: wildcardHandler, parameters: parameters)
            }

            // No match
            return nil
        }

        if let handler = node.handlers[method] {
            return RouteMatch(handler: handler, parameters: parameters)
        }

        // Check for wildcard at this level
        if let wildcardHandler = node.wildcardHandler {
            return RouteMatch(handler: wildcardHandler, parameters: parameters)
        }

        return nil
    }

    public func handle(request: HTTPRequest) async -> HTTPResponse? {
        let method = HTTPMethod(rawValue: request.method.uppercased()) ?? .get
        guard let match = match(method: method, path: request.path) else {
            return nil
        }
        return await match.handler(request)
    }

    // MARK: - Helpers

    private func pathComponents(from path: String) -> [String] {
        path.split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public var count: Int {
        routeCount
    }
}

// MARK: - Typed Route Builder

public struct TypedRoute<Params> {
    public let path: String
    public let parameterExtractor: (HTTPRequest) -> Params?

    public init(path: String, extractor: @escaping (HTTPRequest) -> Params?) {
        self.path = path
        self.parameterExtractor = extractor
    }
}

public struct RouteBuilder {
    // Static route
    public static func route(_ path: String) -> TypedRoute<Void> {
        TypedRoute(path: path) { _ in () }
    }

    // Single parameter route
    public static func route<P1: LosslessStringConvertible>(
        _ path: String,
        _ p1: KeyPath<RouteParams, P1.Type>
    ) -> TypedRoute<P1> {
        let paramName = extractParamName(from: path)
        return TypedRoute(path: path) { request in
            guard let value = request.pathParameters[paramName],
                  let parsed = P1(value) else { return nil }
            return parsed
        }
    }

    // Two parameter route
    public static func route<P1: LosslessStringConvertible, P2: LosslessStringConvertible>(
        _ path: String,
        _ p1: KeyPath<RouteParams, P1.Type>,
        _ p2: KeyPath<RouteParams, P2.Type>
    ) -> TypedRoute<(P1, P2)> {
        let paramNames = extractParamNames(from: path)
        return TypedRoute(path: path) { request in
            guard paramNames.count >= 2,
                  let v1 = request.pathParameters[paramNames[0]],
                  let v2 = request.pathParameters[paramNames[1]],
                  let p1 = P1(v1),
                  let p2 = P2(v2) else { return nil }
            return (p1, p2)
        }
    }

    private static func extractParamName(from path: String) -> String {
        extractParamNames(from: path).first ?? ""
    }

    private static func extractParamNames(from path: String) -> [String] {
        path.split(separator: "/")
            .filter { $0.hasPrefix(":") }
            .map { String($0.dropFirst()) }
    }
}

public struct RouteParams {
    public static var string: String.Type { String.self }
    public static var int: Int.Type { Int.self }
    public static var double: Double.Type { Double.self }
    public static var uuid: UUID.Type { UUID.self }
}

// MARK: - HTTPRequest Extension

public extension HTTPRequest {
    var pathParameters: [String: String] {
        // This would be populated by the router during matching
        [:]
    }
}

// MARK: - Convenience Extensions

public extension TrieRouter {
    /// Register routes using the typed route builder
    func register<P>(
        _ method: HTTPMethod,
        route: TypedRoute<P>,
        handler: @escaping @Sendable (HTTPRequest, P) async -> HTTPResponse
    ) {
        register(method, path: route.path) { request in
            guard let params = route.parameterExtractor(request) else {
                return HTTPResponse(status: .badRequest)
            }
            return await handler(request, params)
        }
    }

    /// DSL for building routes
    func routes(@RouteCollectionBuilder _ builder: () -> [RouteDefinition]) {
        for definition in builder() {
            register(definition.method, path: definition.path, handler: definition.handler)
        }
    }
}

public struct RouteDefinition {
    let method: TrieRouter.HTTPMethod
    let path: String
    let handler: TrieRouter.Handler
}

@resultBuilder
public struct RouteCollectionBuilder {
    public static func buildBlock(_ routes: RouteDefinition...) -> [RouteDefinition] {
        routes
    }
}

public func GET(_ path: String, handler: @escaping TrieRouter.Handler) -> RouteDefinition {
    RouteDefinition(method: .get, path: path, handler: handler)
}

public func POST(_ path: String, handler: @escaping TrieRouter.Handler) -> RouteDefinition {
    RouteDefinition(method: .post, path: path, handler: handler)
}
