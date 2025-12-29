import Foundation
import CryptoKit

public actor HLSSegmentFetcher: SegmentSource {
    public struct ValidationPolicy: Sendable, Equatable {
        public struct Checksum: Sendable, Equatable {
            public enum Algorithm: Sendable, Equatable {
                case sha256
            }

            public let algorithm: Algorithm
            public let value: String

            public init(algorithm: Algorithm, value: String) {
                self.algorithm = algorithm
                self.value = value
            }
        }

        public let enforceByteRangeLength: Bool
        public let checksum: Checksum?
        public let maxSegmentAge: TimeInterval?

        public init(
            enforceByteRangeLength: Bool = true,
            checksum: Checksum? = nil,
            maxSegmentAge: TimeInterval? = nil
        ) {
            self.enforceByteRangeLength = enforceByteRangeLength
            self.checksum = checksum
            self.maxSegmentAge = maxSegmentAge
        }
    }

    public struct RetryPolicy: Sendable, Equatable {
        public var maxRetries: Int
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval
        public var jitterFactor: Double

        public init(
            maxRetries: Int = 3,
            baseDelay: TimeInterval = 0.5,
            maxDelay: TimeInterval = 8,
            jitterFactor: Double = 0.2
        ) {
            self.maxRetries = maxRetries
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.jitterFactor = jitterFactor
        }

        public static let none = RetryPolicy(maxRetries: 0)
        public static let `default` = RetryPolicy()
        public static let aggressive = RetryPolicy(maxRetries: 5, baseDelay: 0.25, maxDelay: 16)
    }

    public struct FetchMetrics: Sendable {
        public let url: URL
        public let byteCount: Int
        public let duration: TimeInterval
        public let retryCount: Int
        public let wasFromCache: Bool

        public init(
            url: URL,
            byteCount: Int,
            duration: TimeInterval,
            retryCount: Int = 0,
            wasFromCache: Bool = false
        ) {
            self.url = url
            self.byteCount = byteCount
            self.duration = duration
            self.retryCount = retryCount
            self.wasFromCache = wasFromCache
        }
    }

    public enum FetchError: Error, Sendable, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case emptyBody
        case lengthMismatch(expected: Int, actual: Int)
        case checksumMismatch
        case timeout
        case networkError(String)
        case cancelled
        case staleSegment(age: TimeInterval)
        case circuitBreakerOpen

        public var isRetryable: Bool {
            switch self {
            case .httpStatus(let code):
                return code >= 500 || code == 429
            case .timeout, .networkError:
                return true
            case .invalidResponse, .emptyBody, .lengthMismatch, .checksumMismatch,
                 .cancelled, .staleSegment, .circuitBreakerOpen:
                return false
            }
        }

        public var category: ErrorCategory {
            switch self {
            case .invalidResponse, .emptyBody, .lengthMismatch, .checksumMismatch:
                return .validation
            case .httpStatus(let code) where code >= 500:
                return .server
            case .httpStatus(let code) where code >= 400:
                return .client
            case .httpStatus:
                return .unknown
            case .timeout:
                return .timeout
            case .networkError:
                return .network
            case .cancelled:
                return .cancelled
            case .staleSegment:
                return .stale
            case .circuitBreakerOpen:
                return .circuitBreaker
            }
        }
    }

    public enum ErrorCategory: String, Sendable, CaseIterable {
        case validation
        case server
        case client
        case timeout
        case network
        case cancelled
        case stale
        case circuitBreaker
        case unknown
    }

    public struct ErrorTelemetry: Sendable {
        public let url: URL
        public let error: FetchError
        public let category: ErrorCategory
        public let timestamp: Date
        public let retryCount: Int
        public let duration: TimeInterval

        public init(
            url: URL,
            error: FetchError,
            category: ErrorCategory,
            timestamp: Date = Date(),
            retryCount: Int = 0,
            duration: TimeInterval = 0
        ) {
            self.url = url
            self.error = error
            self.category = category
            self.timestamp = timestamp
            self.retryCount = retryCount
            self.duration = duration
        }
    }

    private let session: URLSession
    private var validationPolicy: ValidationPolicy
    private var retryPolicy: RetryPolicy
    private var timeout: TimeInterval
    private var metricsHandler: (@Sendable (FetchMetrics) async -> Void)?
    private var errorHandler: (@Sendable (ErrorTelemetry) async -> Void)?
    private var latestMetricsValue: FetchMetrics?
    private let circuitBreaker: CircuitBreaker

    public init(
        session: URLSession = .shared,
        validationPolicy: ValidationPolicy = .init(),
        retryPolicy: RetryPolicy = .default,
        timeout: TimeInterval = 20,
        circuitBreakerConfig: CircuitBreaker.Configuration = .init()
    ) {
        self.session = session
        self.validationPolicy = validationPolicy
        self.retryPolicy = retryPolicy
        self.timeout = timeout
        self.circuitBreaker = CircuitBreaker(configuration: circuitBreakerConfig)
    }

    public func updateValidationPolicy(_ policy: ValidationPolicy) {
        validationPolicy = policy
    }

    public func updateRetryPolicy(_ policy: RetryPolicy) {
        retryPolicy = policy
    }

    public func updateTimeout(_ timeout: TimeInterval) {
        self.timeout = timeout
    }

    public func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        try await fetchSegment(from: segment.url, metadata: segment)
    }

    public func fetchPartialSegment(_ part: HLSPartialSegment) async throws -> Data {
        try await fetchSegment(from: part.url, metadata: part.asSegment())
    }

    public func fetchSegment(from url: URL) async throws -> Data {
        try await fetchSegment(from: url, metadata: nil)
    }

    public func onMetrics(_ handler: (@Sendable (FetchMetrics) async -> Void)?) {
        metricsHandler = handler
    }

    public func onError(_ handler: (@Sendable (ErrorTelemetry) async -> Void)?) {
        errorHandler = handler
    }

    public func latestMetrics() -> FetchMetrics? {
        latestMetricsValue
    }

    public func circuitBreakerState() -> CircuitBreaker.State {
        circuitBreaker.state
    }

    private func fetchSegment(from url: URL, metadata: HLSSegment?) async throws -> Data {
        let startTime = Date()
        var lastError: FetchError?
        var retryCount = 0

        // Check circuit breaker
        guard circuitBreaker.allowRequest() else {
            let error = FetchError.circuitBreakerOpen
            await reportError(url: url, error: error, retryCount: 0, duration: 0)
            throw error
        }

        while retryCount <= retryPolicy.maxRetries {
            do {
                try Task.checkCancellation()
                let data = try await performFetch(from: url, metadata: metadata)
                let duration = Date().timeIntervalSince(startTime)

                circuitBreaker.recordSuccess()

                let metrics = FetchMetrics(
                    url: url,
                    byteCount: data.count,
                    duration: duration,
                    retryCount: retryCount
                )
                latestMetricsValue = metrics
                if let metricsHandler {
                    await metricsHandler(metrics)
                }

                return data
            } catch is CancellationError {
                let error = FetchError.cancelled
                await reportError(url: url, error: error, retryCount: retryCount, duration: Date().timeIntervalSince(startTime))
                throw error
            } catch let error as FetchError {
                lastError = error
                circuitBreaker.recordFailure()

                if !error.isRetryable || retryCount >= retryPolicy.maxRetries {
                    await reportError(url: url, error: error, retryCount: retryCount, duration: Date().timeIntervalSince(startTime))
                    throw error
                }

                let delay = calculateRetryDelay(attempt: retryCount)
                retryCount += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                let fetchError = mapToFetchError(error)
                lastError = fetchError
                circuitBreaker.recordFailure()

                if !fetchError.isRetryable || retryCount >= retryPolicy.maxRetries {
                    await reportError(url: url, error: fetchError, retryCount: retryCount, duration: Date().timeIntervalSince(startTime))
                    throw fetchError
                }

                let delay = calculateRetryDelay(attempt: retryCount)
                retryCount += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        let error = lastError ?? FetchError.networkError("Max retries exceeded")
        await reportError(url: url, error: error, retryCount: retryCount, duration: Date().timeIntervalSince(startTime))
        throw error
    }

    private func performFetch(from url: URL, metadata: HLSSegment?) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw FetchError.emptyBody
        }

        // Check for stale segment
        if let maxAge = validationPolicy.maxSegmentAge,
           let dateHeader = http.value(forHTTPHeaderField: "Date"),
           let serverDate = parseHTTPDate(dateHeader) {
            let age = Date().timeIntervalSince(serverDate)
            if age > maxAge {
                throw FetchError.staleSegment(age: age)
            }
        }

        try validate(data: data, metadata: metadata)

        return data
    }

    private func mapToFetchError(_ error: Error) -> FetchError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return .networkError(urlError.localizedDescription)
            default:
                return .networkError(urlError.localizedDescription)
            }
        }
        return .networkError(error.localizedDescription)
    }

    private func calculateRetryDelay(attempt: Int) -> TimeInterval {
        let exponentialDelay = retryPolicy.baseDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(exponentialDelay, retryPolicy.maxDelay)

        // Add jitter
        let jitterRange = cappedDelay * retryPolicy.jitterFactor
        let jitter = Double.random(in: -jitterRange...jitterRange)

        return max(0.01, cappedDelay + jitter)
    }

    private func reportError(url: URL, error: FetchError, retryCount: Int, duration: TimeInterval) async {
        guard let errorHandler else { return }
        let telemetry = ErrorTelemetry(
            url: url,
            error: error,
            category: error.category,
            retryCount: retryCount,
            duration: duration
        )
        await errorHandler(telemetry)
    }

    private func parseHTTPDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        // RFC 7231 format
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: dateString) {
            return date
        }

        // RFC 850 format
        formatter.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: dateString) {
            return date
        }

        // ANSI C format
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: dateString)
    }

    private func validate(data: Data, metadata: HLSSegment?) throws {
        if validationPolicy.enforceByteRangeLength, let range = metadata?.byteRange {
            let expectedLength = range.count
            if data.count != expectedLength {
                throw FetchError.lengthMismatch(expected: expectedLength, actual: data.count)
            }
        }

        if let checksum = validationPolicy.checksum {
            let digest: String
            switch checksum.algorithm {
            case .sha256:
                digest = SHA256.hash(data: data)
                    .map { String(format: "%02hhx", $0) }
                    .joined()
            }
            if digest.lowercased() != checksum.value.lowercased() {
                throw FetchError.checksumMismatch
            }
        }
    }
}

// MARK: - Circuit Breaker

public final class CircuitBreaker: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var failureThreshold: Int
        public var successThreshold: Int
        public var resetTimeout: TimeInterval

        public init(
            failureThreshold: Int = 5,
            successThreshold: Int = 2,
            resetTimeout: TimeInterval = 30
        ) {
            self.failureThreshold = failureThreshold
            self.successThreshold = successThreshold
            self.resetTimeout = resetTimeout
        }
    }

    public enum State: Sendable {
        case closed
        case open
        case halfOpen
    }

    private let configuration: Configuration
    private var _state: State = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private var lastFailureTime: Date?
    private let lock = NSLock()

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        updateStateIfNeeded()
        return _state
    }

    public func allowRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        updateStateIfNeeded()

        switch _state {
        case .closed:
            return true
        case .open:
            return false
        case .halfOpen:
            return true
        }
    }

    public func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }

        switch _state {
        case .closed:
            failureCount = 0
        case .open:
            break
        case .halfOpen:
            successCount += 1
            if successCount >= configuration.successThreshold {
                _state = .closed
                failureCount = 0
                successCount = 0
            }
        }
    }

    public func recordFailure() {
        lock.lock()
        defer { lock.unlock() }

        failureCount += 1
        lastFailureTime = Date()

        switch _state {
        case .closed:
            if failureCount >= configuration.failureThreshold {
                _state = .open
            }
        case .open:
            break
        case .halfOpen:
            _state = .open
            successCount = 0
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _state = .closed
        failureCount = 0
        successCount = 0
        lastFailureTime = nil
    }

    private func updateStateIfNeeded() {
        guard _state == .open,
              let lastFailure = lastFailureTime,
              Date().timeIntervalSince(lastFailure) >= configuration.resetTimeout
        else { return }

        _state = .halfOpen
        successCount = 0
    }
}
