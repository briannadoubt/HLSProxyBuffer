import Foundation

/// Token bucket rate limiter for proxy endpoints
public actor RateLimiter {
    public struct Configuration: Sendable {
        public var requestsPerSecond: Double
        public var burstCapacity: Int

        public init(requestsPerSecond: Double = 100, burstCapacity: Int = 20) {
            self.requestsPerSecond = max(0.1, requestsPerSecond)
            self.burstCapacity = max(1, burstCapacity)
        }
    }

    private var tokens: Double
    private var lastRefill: Date
    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.tokens = Double(configuration.burstCapacity)
        self.lastRefill = Date()
    }

    /// Attempts to acquire a token. Returns true if allowed, false if rate limited.
    public func acquire() -> Bool {
        refillTokens()
        if tokens >= 1 {
            tokens -= 1
            return true
        }
        return false
    }

    /// Returns the current number of available tokens
    public func availableTokens() -> Double {
        refillTokens()
        return tokens
    }

    /// Returns time until next token is available (0 if tokens available)
    public func waitTime() -> TimeInterval {
        refillTokens()
        if tokens >= 1 {
            return 0
        }
        let tokensNeeded = 1 - tokens
        return tokensNeeded / configuration.requestsPerSecond
    }

    private func refillTokens() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let newTokens = elapsed * configuration.requestsPerSecond
        tokens = min(Double(configuration.burstCapacity), tokens + newTokens)
        lastRefill = now
    }
}

/// Rate limiting middleware for the proxy router
public struct RateLimitingMiddleware: Sendable {
    private let limiter: RateLimiter
    private let isEnabled: Bool

    public init(configuration: RateLimiter.Configuration, isEnabled: Bool = true) {
        self.limiter = RateLimiter(configuration: configuration)
        self.isEnabled = isEnabled
    }

    public func wrap(_ handler: @escaping ProxyRouter.Handler) -> ProxyRouter.Handler {
        guard isEnabled else { return handler }

        return { @Sendable request in
            let allowed = await limiter.acquire()
            if allowed {
                return await handler(request)
            } else {
                return HTTPResponse(
                    status: .tooManyRequests,
                    headers: [
                        "Retry-After": "1",
                        "X-RateLimit-Remaining": "0"
                    ]
                )
            }
        }
    }
}
