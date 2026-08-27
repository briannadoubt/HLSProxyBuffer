import Foundation

/// URL loading policy for manifests, media segments, and origin-hosted assets.
public struct HLSOriginNetworkPolicy: Sendable, Equatable {
    public static let `default` = HLSOriginNetworkPolicy()

    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval
    public let waitsForConnectivity: Bool
    public let allowsConstrainedNetworkAccess: Bool
    public let allowsExpensiveNetworkAccess: Bool
    public let maximumConnectionsPerHost: Int

    public init(
        requestTimeout: TimeInterval = 20,
        resourceTimeout: TimeInterval = 60,
        waitsForConnectivity: Bool = false,
        allowsConstrainedNetworkAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        maximumConnectionsPerHost: Int = 6
    ) {
        let normalizedRequestTimeout = Self.positiveTimeout(requestTimeout, fallback: 20)
        self.requestTimeout = normalizedRequestTimeout
        self.resourceTimeout = max(
            normalizedRequestTimeout,
            Self.positiveTimeout(resourceTimeout, fallback: 60)
        )
        self.waitsForConnectivity = waitsForConnectivity
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.maximumConnectionsPerHost = max(1, maximumConnectionsPerHost)
    }

    /// Creates an ephemeral URLSession configuration suitable for origin traffic.
    /// HLSProxyBuffer owns its media cache, so URL loading's response cache is disabled.
    public func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    public func makeURLSession() -> URLSession {
        URLSession(configuration: makeURLSessionConfiguration())
    }

    private static func positiveTimeout(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite, value > 0 else { return fallback }
        return value
    }
}
