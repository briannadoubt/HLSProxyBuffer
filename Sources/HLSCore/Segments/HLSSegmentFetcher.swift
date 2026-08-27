import Foundation
import CryptoKit

public actor HLSSegmentFetcher: SegmentSource {
    public struct RetryPolicy: Sendable, Equatable {
        public static let `default` = RetryPolicy()

        public let maxAttempts: Int
        public let initialDelay: TimeInterval
        public let multiplier: Double
        public let maximumDelay: TimeInterval
        public let jitterRatio: Double
        public let maximumRetryAfter: TimeInterval

        public init(
            maxAttempts: Int = 3,
            initialDelay: TimeInterval = 0.25,
            multiplier: Double = 2,
            maximumDelay: TimeInterval = 8,
            jitterRatio: Double = 0.2,
            maximumRetryAfter: TimeInterval = 60
        ) {
            let normalizedInitialDelay = Self.nonnegativeFinite(initialDelay)
            self.maxAttempts = max(1, maxAttempts)
            self.initialDelay = normalizedInitialDelay
            self.multiplier = max(1, multiplier.isFinite ? multiplier : 1)
            self.maximumDelay = max(
                normalizedInitialDelay,
                Self.nonnegativeFinite(maximumDelay)
            )
            self.jitterRatio = min(max(0, jitterRatio.isFinite ? jitterRatio : 0), 1)
            self.maximumRetryAfter = Self.nonnegativeFinite(maximumRetryAfter)
        }

        public func isRetryable(statusCode: Int) -> Bool {
            statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        }

        public func isRetryable(urlErrorCode: URLError.Code) -> Bool {
            switch urlErrorCode {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .cannotLoadFromNetwork,
                 .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }

        fileprivate func delay(
            afterAttempt attempt: Int,
            retryAfter: TimeInterval?,
            jitterSample: Double
        ) -> TimeInterval {
            let exponent = pow(multiplier, Double(max(0, attempt - 1)))
            let exponential = min(maximumDelay, initialDelay * exponent)
            let sample = jitterSample.isFinite ? min(max(jitterSample, -1), 1) : 0
            let jittered = max(0, exponential + exponential * jitterRatio * sample)
            let serverDelay = min(maximumRetryAfter, max(0, retryAfter ?? 0))
            return max(jittered, serverDelay)
        }

        private static func nonnegativeFinite(_ value: TimeInterval) -> TimeInterval {
            value.isFinite ? max(0, value) : 0
        }
    }

    /// Injectable wall/monotonic clock pair used by retry scheduling.
    public struct RetryClock: Sendable {
        public static let continuous = RetryClock(
            now: { Date() },
            sleep: { delay in
                guard delay > 0 else {
                    try Task.checkCancellation()
                    return
                }
                try await ContinuousClock().sleep(for: .seconds(delay))
            }
        )

        private let nowProvider: @Sendable () -> Date
        private let sleepProvider: @Sendable (TimeInterval) async throws -> Void

        public init(
            now: @escaping @Sendable () -> Date,
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void
        ) {
            self.nowProvider = now
            self.sleepProvider = sleep
        }

        fileprivate func now() -> Date {
            nowProvider()
        }

        fileprivate func sleep(for delay: TimeInterval) async throws {
            try await sleepProvider(delay)
        }
    }

    /// Injectable normalized random sample used to jitter retry delays.
    public struct RetryJitterSource: Sendable {
        public static let random = RetryJitterSource {
            Double.random(in: -1...1)
        }

        private let provider: @Sendable () -> Double

        public init(nextValue: @escaping @Sendable () -> Double) {
            self.provider = nextValue
        }

        fileprivate func nextValue() -> Double {
            provider()
        }
    }

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

        public init(enforceByteRangeLength: Bool = true, checksum: Checksum? = nil) {
            self.enforceByteRangeLength = enforceByteRangeLength
            self.checksum = checksum
        }
    }

    public struct FetchMetrics: Sendable {
        public let url: URL
        public let byteCount: Int
        public let duration: TimeInterval
        public let attemptCount: Int
        public let retryCount: Int

        public init(
            url: URL,
            byteCount: Int,
            duration: TimeInterval,
            attemptCount: Int = 1,
            retryCount: Int = 0
        ) {
            self.url = url
            self.byteCount = byteCount
            self.duration = duration
            self.attemptCount = max(1, attemptCount)
            self.retryCount = max(0, retryCount)
        }
    }

    public enum FetchError: Error {
        case invalidResponse
        case httpStatus(Int)
        case emptyBody
        case lengthMismatch(expected: Int, actual: Int)
        case invalidContentRange(String?)
        case checksumMismatch
    }

    private var session: URLSession
    private var networkPolicy: HLSOriginNetworkPolicy
    private let managesSession: Bool
    private var validationPolicy: ValidationPolicy
    private var retryPolicy: RetryPolicy
    private let retryClock: RetryClock
    private let retryJitterSource: RetryJitterSource
    private var metricsHandler: (@Sendable (FetchMetrics) async -> Void)?
    private var latestMetricsValue: FetchMetrics?
    private var inFlight: [FetchKey: InFlight] = [:]

    private struct FetchKey: Hashable, Sendable {
        let url: URL
        let byteRange: ClosedRange<Int>?
    }

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }

    private struct AttemptFailure: Error {
        let underlying: Error
        let retryAfter: TimeInterval?
    }

    public init(
        session: URLSession? = nil,
        validationPolicy: ValidationPolicy = .init(),
        networkPolicy: HLSOriginNetworkPolicy = .default,
        retryPolicy: RetryPolicy = .default,
        retryClock: RetryClock = .continuous,
        retryJitterSource: RetryJitterSource = .random
    ) {
        self.session = session ?? networkPolicy.makeURLSession()
        self.networkPolicy = networkPolicy
        self.managesSession = session == nil
        self.validationPolicy = validationPolicy
        self.retryPolicy = retryPolicy
        self.retryClock = retryClock
        self.retryJitterSource = retryJitterSource
    }

    public func updateValidationPolicy(_ policy: ValidationPolicy) {
        validationPolicy = policy
    }

    public func updateNetworkPolicy(_ policy: HLSOriginNetworkPolicy) {
        guard policy != networkPolicy else { return }
        networkPolicy = policy
        guard managesSession else { return }
        let previousSession = session
        session = policy.makeURLSession()
        previousSession.finishTasksAndInvalidate()
    }

    public func updateRetryPolicy(_ policy: RetryPolicy) {
        retryPolicy = policy
    }

    public func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        try await fetchSegment(from: segment.url, metadata: segment)
    }

    public func fetchSegment(from url: URL) async throws -> Data {
        try await fetchSegment(from: url, metadata: nil)
    }

    public func fetchResource(at url: URL, byteRange: ClosedRange<Int>?) async throws -> Data {
        try await fetchSegment(
            from: url,
            metadata: HLSSegment(url: url, duration: 0, sequence: 0, byteRange: byteRange)
        )
    }

    public func onMetrics(_ handler: (@Sendable (FetchMetrics) async -> Void)?) {
        metricsHandler = handler
    }

    public func latestMetrics() -> FetchMetrics? {
        latestMetricsValue
    }

    private func fetchSegment(from url: URL, metadata: HLSSegment?) async throws -> Data {
        let key = FetchKey(url: url, byteRange: metadata?.byteRange)
        let waiterID = UUID()
        let inFlightID: UUID
        let task: Task<Data, Error>

        if var existing = inFlight[key] {
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            inFlightID = existing.id
            task = existing.task
        } else {
            let id = UUID()
            let newTask = Task { try await performFetch(from: url, metadata: metadata) }
            inFlight[key] = InFlight(id: id, task: newTask, waiters: [waiterID])
            inFlightID = id
            task = newTask
        }

        do {
            let data = try await withTaskCancellationHandler {
                let data = try await task.value
                try Task.checkCancellation()
                return data
            } onCancel: {
                Task {
                    await self.cancelWaiter(key: key, inFlightID: inFlightID, waiterID: waiterID)
                }
            }
            finishWaiter(key: key, inFlightID: inFlightID, waiterID: waiterID)
            return data
        } catch {
            if Task.isCancelled {
                cancelWaiter(key: key, inFlightID: inFlightID, waiterID: waiterID)
                throw CancellationError()
            }
            finishWaiter(key: key, inFlightID: inFlightID, waiterID: waiterID)
            throw error
        }
    }

    private func finishWaiter(key: FetchKey, inFlightID: UUID, waiterID: UUID) {
        guard var entry = inFlight[key], entry.id == inFlightID else { return }
        entry.waiters.remove(waiterID)
        if entry.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }

    private func cancelWaiter(key: FetchKey, inFlightID: UUID, waiterID: UUID) {
        guard var entry = inFlight[key], entry.id == inFlightID else { return }
        entry.waiters.remove(waiterID)
        if entry.waiters.isEmpty {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }

    private func performFetch(from url: URL, metadata: HLSSegment?) async throws -> Data {
        try Task.checkCancellation()
        let start = retryClock.now()

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let data = try await fetchAttempt(from: url, metadata: metadata)
                let metrics = FetchMetrics(
                    url: url,
                    byteCount: data.count,
                    duration: max(0, retryClock.now().timeIntervalSince(start)),
                    attemptCount: attempt,
                    retryCount: attempt - 1
                )
                latestMetricsValue = metrics
                if let metricsHandler {
                    await metricsHandler(metrics)
                }
                return data
            } catch {
                let failure = error as? AttemptFailure
                let underlying = failure?.underlying ?? error
                if Task.isCancelled
                    || underlying is CancellationError
                    || (underlying as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }

                guard attempt < retryPolicy.maxAttempts,
                      isRetryable(underlying) else {
                    throw underlying
                }

                let delay = retryPolicy.delay(
                    afterAttempt: attempt,
                    retryAfter: failure?.retryAfter,
                    jitterSample: retryJitterSource.nextValue()
                )
                try Task.checkCancellation()
                try await retryClock.sleep(for: delay)
            }
        }

        throw FetchError.invalidResponse
    }

    private func fetchAttempt(from url: URL, metadata: HLSSegment?) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = networkPolicy.requestTimeout
        if let range = metadata?.byteRange {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }

        let (receivedData, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AttemptFailure(
                underlying: FetchError.httpStatus(http.statusCode),
                retryAfter: retryAfterDelay(from: http)
            )
        }
        let data = try normalizedData(
            receivedData,
            response: http,
            requestedRange: metadata?.byteRange
        )
        guard !data.isEmpty else {
            throw FetchError.emptyBody
        }

        try validate(data: data, metadata: metadata)
        return data
    }

    private func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return retryPolicy.isRetryable(urlErrorCode: urlError.code)
        }
        guard let fetchError = error as? FetchError else { return false }
        switch fetchError {
        case .httpStatus(let statusCode):
            return retryPolicy.isRetryable(statusCode: statusCode)
        case .invalidResponse,
             .emptyBody,
             .lengthMismatch,
             .invalidContentRange,
             .checksumMismatch:
            return true
        }
    }

    private func retryAfterDelay(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(rawValue), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let locale = Locale(identifier: "en_US_POSIX")
        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                return max(0, date.timeIntervalSince(retryClock.now()))
            }
        }
        return nil
    }

    private func normalizedData(
        _ data: Data,
        response: HTTPURLResponse,
        requestedRange: ClosedRange<Int>?
    ) throws -> Data {
        guard let requestedRange else { return data }
        if response.statusCode == 206 {
            let header = response.value(forHTTPHeaderField: "Content-Range")
            guard contentRange(header, matches: requestedRange) else {
                throw FetchError.invalidContentRange(header)
            }
            return data
        }

        if data.count == requestedRange.count {
            return data
        }
        guard requestedRange.lowerBound >= 0, requestedRange.upperBound < data.count else {
            throw FetchError.lengthMismatch(expected: requestedRange.count, actual: data.count)
        }
        return data.subdata(in: requestedRange.lowerBound..<(requestedRange.upperBound + 1))
    }

    private func contentRange(_ value: String?, matches expected: ClosedRange<Int>) -> Bool {
        guard let value else { return false }
        let prefix = "bytes \(expected.lowerBound)-\(expected.upperBound)/"
        return value.lowercased().hasPrefix(prefix)
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
