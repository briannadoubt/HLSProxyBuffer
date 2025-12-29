import Foundation

/// Network configuration for HLS segment and manifest fetching
public struct NetworkConfiguration: Sendable {
    public enum HTTPVersion: Sendable {
        case http1_1
        case http2
        case automatic
    }

    public enum NetworkInterface: Sendable {
        case any
        case wifi
        case cellular
        case wired
    }

    public var httpVersion: HTTPVersion
    public var timeout: TimeInterval
    public var connectionKeepAlive: Bool
    public var maxConnectionsPerHost: Int
    public var preferredInterface: NetworkInterface
    public var allowsExpensiveNetworkAccess: Bool
    public var allowsConstrainedNetworkAccess: Bool
    public var waitsForConnectivity: Bool

    public init(
        httpVersion: HTTPVersion = .automatic,
        timeout: TimeInterval = 20,
        connectionKeepAlive: Bool = true,
        maxConnectionsPerHost: Int = 6,
        preferredInterface: NetworkInterface = .any,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        waitsForConnectivity: Bool = false
    ) {
        self.httpVersion = httpVersion
        self.timeout = timeout
        self.connectionKeepAlive = connectionKeepAlive
        self.maxConnectionsPerHost = maxConnectionsPerHost
        self.preferredInterface = preferredInterface
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.waitsForConnectivity = waitsForConnectivity
    }

    /// Creates a URLSessionConfiguration based on these settings
    public func makeURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default

        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3

        // HTTP/2 settings
        switch httpVersion {
        case .http1_1:
            // Disable HTTP/2 by setting protocols
            config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        case .http2, .automatic:
            // HTTP/2 is enabled by default in modern URLSession
            config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        }

        // Connection settings
        config.httpShouldUsePipelining = httpVersion != .http1_1
        config.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        config.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        config.waitsForConnectivity = waitsForConnectivity

        // Cache policy - we manage our own cache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil

        return config
    }

    /// Creates a URLSession with these settings
    public func makeURLSession(delegate: URLSessionDelegate? = nil) -> URLSession {
        URLSession(configuration: makeURLSessionConfiguration(), delegate: delegate, delegateQueue: nil)
    }
}

// MARK: - Presets

public extension NetworkConfiguration {
    /// Preset for low-latency live streaming
    static var lowLatency: NetworkConfiguration {
        NetworkConfiguration(
            httpVersion: .http2,
            timeout: 10,
            connectionKeepAlive: true,
            maxConnectionsPerHost: 4,
            waitsForConnectivity: false
        )
    }

    /// Preset for VOD playback with aggressive caching
    static var vod: NetworkConfiguration {
        NetworkConfiguration(
            httpVersion: .automatic,
            timeout: 30,
            connectionKeepAlive: true,
            maxConnectionsPerHost: 6,
            waitsForConnectivity: true
        )
    }

    /// Preset for cellular/mobile networks
    static var mobile: NetworkConfiguration {
        NetworkConfiguration(
            httpVersion: .http2,
            timeout: 25,
            connectionKeepAlive: true,
            maxConnectionsPerHost: 4,
            preferredInterface: .cellular,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true
        )
    }

    /// Preset for WiFi-preferred playback
    static var wifiPreferred: NetworkConfiguration {
        NetworkConfiguration(
            httpVersion: .http2,
            timeout: 15,
            connectionKeepAlive: true,
            maxConnectionsPerHost: 8,
            preferredInterface: .wifi,
            allowsExpensiveNetworkAccess: false
        )
    }
}
