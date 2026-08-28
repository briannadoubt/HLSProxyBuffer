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

    public struct OriginValidation: Equatable, Sendable {
        public let eTag: String?
        public let lastModified: String?
        public let maximumAge: TimeInterval?
        public let allowsStorage: Bool

        public init(
            eTag: String? = nil,
            lastModified: String? = nil,
            maximumAge: TimeInterval? = nil,
            allowsStorage: Bool = true
        ) {
            self.eTag = eTag
            self.lastModified = lastModified
            self.maximumAge = maximumAge.map { max(0, $0) }
            self.allowsStorage = allowsStorage
        }
    }

    public enum ValidatedResource: Equatable, Sendable {
        case modified(Data, validation: OriginValidation)
        case notModified(validation: OriginValidation)

        fileprivate var byteCount: Int {
            switch self {
            case .modified(let data, _): data.count
            case .notModified: 0
            }
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

    public enum FetchErrorCategory: String, CaseIterable, Hashable, Sendable {
        case timeout
        case dns
        case connectivity
        case rateLimited = "rate_limited"
        case httpClient = "http_client"
        case httpServer = "http_server"
        case invalidResponse = "invalid_response"
        case emptyBody = "empty_body"
        case rangeValidation = "range_validation"
        case checksum
        case cancelled
        case other
    }

    public enum RetryOutcome: String, CaseIterable, Hashable, Sendable {
        case successWithoutRetry = "success_without_retry"
        case successAfterRetry = "success_after_retry"
        case failureWithoutRetry = "failure_without_retry"
        case failureAfterRetry = "failure_after_retry"
        case cancelled
    }

    public struct FetchEvent: Equatable, Sendable {
        public let url: URL
        public let duration: TimeInterval
        public let byteCount: Int
        public let attemptCount: Int
        public let retryCount: Int
        public let retryOutcome: RetryOutcome
        public let errorCategory: FetchErrorCategory?

        public init(
            url: URL,
            duration: TimeInterval,
            byteCount: Int,
            attemptCount: Int,
            retryCount: Int,
            retryOutcome: RetryOutcome,
            errorCategory: FetchErrorCategory?
        ) {
            self.url = url
            self.duration = duration.isFinite ? max(0, duration) : 0
            self.byteCount = max(0, byteCount)
            self.attemptCount = max(1, attemptCount)
            self.retryCount = max(0, retryCount)
            self.retryOutcome = retryOutcome
            self.errorCategory = errorCategory
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
    private var eventHandler: (@Sendable (FetchEvent) async -> Void)?
    private var latestMetricsValue: FetchMetrics?
    private var inFlight: [FetchKey: InFlight] = [:]

    private struct FetchKey: Hashable, Sendable {
        let url: URL
        let byteRange: ClosedRange<Int>?
        let ifNoneMatch: String?
        let ifModifiedSince: String?
    }

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<ValidatedResource, Error>
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
        try await requiredData(
            from: fetchValidatedResource(
                at: segment.url,
                byteRange: segment.byteRange
            )
        )
    }

    public func fetchSegment(from url: URL) async throws -> Data {
        try await requiredData(from: fetchValidatedResource(at: url, byteRange: nil))
    }

    public func fetchResource(at url: URL, byteRange: ClosedRange<Int>?) async throws -> Data {
        try await requiredData(from: fetchValidatedResource(at: url, byteRange: byteRange))
    }

    /// Fetches one resource with optional conditional validators. A 304 keeps
    /// cached bytes authoritative and avoids charging response-body bytes.
    public func fetchValidatedResource(
        at url: URL,
        byteRange: ClosedRange<Int>?,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil
    ) async throws -> ValidatedResource {
        try await fetchSegment(
            from: url,
            metadata: HLSSegment(url: url, duration: 0, sequence: 0, byteRange: byteRange),
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: ifModifiedSince
        )
    }

    public func onMetrics(_ handler: (@Sendable (FetchMetrics) async -> Void)?) {
        metricsHandler = handler
    }

    public func onEvent(_ handler: (@Sendable (FetchEvent) async -> Void)?) {
        eventHandler = handler
    }

    public func latestMetrics() -> FetchMetrics? {
        latestMetricsValue
    }

    private func fetchSegment(
        from url: URL,
        metadata: HLSSegment?,
        ifNoneMatch: String?,
        ifModifiedSince: String?
    ) async throws -> ValidatedResource {
        let key = FetchKey(
            url: url,
            byteRange: metadata?.byteRange,
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: ifModifiedSince
        )
        let waiterID = UUID()
        let inFlightID: UUID
        let task: Task<ValidatedResource, Error>

        if var existing = inFlight[key] {
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            inFlightID = existing.id
            task = existing.task
        } else {
            let id = UUID()
            let newTask = Task {
                try await performFetch(
                    from: url,
                    metadata: metadata,
                    ifNoneMatch: ifNoneMatch,
                    ifModifiedSince: ifModifiedSince
                )
            }
            inFlight[key] = InFlight(id: id, task: newTask, waiters: [waiterID])
            inFlightID = id
            task = newTask
        }

        do {
            let data = try await withTaskCancellationHandler {
                let resource = try await task.value
                try Task.checkCancellation()
                return resource
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

    private func performFetch(
        from url: URL,
        metadata: HLSSegment?,
        ifNoneMatch: String?,
        ifModifiedSince: String?
    ) async throws -> ValidatedResource {
        try Task.checkCancellation()
        let start = retryClock.now()

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let resource = try await fetchAttempt(
                    from: url,
                    metadata: metadata,
                    ifNoneMatch: ifNoneMatch,
                    ifModifiedSince: ifModifiedSince
                )
                let metrics = FetchMetrics(
                    url: url,
                    byteCount: resource.byteCount,
                    duration: max(0, retryClock.now().timeIntervalSince(start)),
                    attemptCount: attempt,
                    retryCount: attempt - 1
                )
                latestMetricsValue = metrics
                if let metricsHandler {
                    await metricsHandler(metrics)
                }
                await emitEvent(
                    url: url,
                    start: start,
                    byteCount: resource.byteCount,
                    attemptCount: attempt,
                    outcome: attempt > 1 ? .successAfterRetry : .successWithoutRetry,
                    errorCategory: nil
                )
                return resource
            } catch {
                let failure = error as? AttemptFailure
                let underlying = failure?.underlying ?? error
                if Task.isCancelled
                    || underlying is CancellationError
                    || (underlying as? URLError)?.code == .cancelled {
                    await emitEvent(
                        url: url,
                        start: start,
                        byteCount: 0,
                        attemptCount: attempt,
                        outcome: .cancelled,
                        errorCategory: .cancelled
                    )
                    throw CancellationError()
                }

                guard attempt < retryPolicy.maxAttempts,
                      isRetryable(underlying) else {
                    await emitEvent(
                        url: url,
                        start: start,
                        byteCount: 0,
                        attemptCount: attempt,
                        outcome: attempt > 1 ? .failureAfterRetry : .failureWithoutRetry,
                        errorCategory: errorCategory(for: underlying)
                    )
                    throw underlying
                }

                let delay = retryPolicy.delay(
                    afterAttempt: attempt,
                    retryAfter: failure?.retryAfter,
                    jitterSample: retryJitterSource.nextValue()
                )
                do {
                    try Task.checkCancellation()
                    try await retryClock.sleep(for: delay)
                } catch {
                    let wasCancelled = Task.isCancelled || error is CancellationError
                    await emitEvent(
                        url: url,
                        start: start,
                        byteCount: 0,
                        attemptCount: attempt,
                        outcome: wasCancelled ? .cancelled : .failureAfterRetry,
                        errorCategory: wasCancelled ? .cancelled : .other
                    )
                    if wasCancelled {
                        throw CancellationError()
                    }
                    throw error
                }
            }
        }

        throw FetchError.invalidResponse
    }

    private func fetchAttempt(
        from url: URL,
        metadata: HLSSegment?,
        ifNoneMatch: String?,
        ifModifiedSince: String?
    ) async throws -> ValidatedResource {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = networkPolicy.requestTimeout
        if let range = metadata?.byteRange {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        if let ifNoneMatch = Self.safeValidator(ifNoneMatch) {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let ifModifiedSince = Self.safeValidator(ifModifiedSince) {
            request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }

        let (receivedData, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        let originValidation = OriginValidation(
            eTag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            maximumAge: Self.maximumAge(
                from: http.value(forHTTPHeaderField: "Cache-Control")
            ),
            allowsStorage: Self.allowsStorage(
                cacheControl: http.value(forHTTPHeaderField: "Cache-Control")
            )
        )
        if http.statusCode == 304 {
            return .notModified(validation: originValidation)
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
        return .modified(data, validation: originValidation)
    }

    private func requiredData(from resource: ValidatedResource) throws -> Data {
        guard case .modified(let data, _) = resource else {
            throw FetchError.invalidResponse
        }
        return data
    }

    private static func maximumAge(from cacheControl: String?) -> TimeInterval? {
        guard let cacheControl else { return nil }
        for directive in cacheControl.split(separator: ",") {
            let pair = directive.split(separator: "=", maxSplits: 1)
            if pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("no-cache") == .orderedSame {
                return 0
            }
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("max-age") == .orderedSame
            else { continue }
            let raw = pair[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let value = TimeInterval(raw), value.isFinite else { return nil }
            return max(0, value)
        }
        return nil
    }

    private static func allowsStorage(cacheControl: String?) -> Bool {
        guard let cacheControl else { return true }
        return !cacheControl.split(separator: ",").contains { directive in
            directive.split(separator: "=", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("no-store") == .orderedSame
        }
    }

    private static func safeValidator(_ value: String?) -> String? {
        guard let value,
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              })
        else { return nil }
        return String(value.prefix(512))
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

    private func errorCategory(for error: Error) -> FetchErrorCategory {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cannotFindHost, .dnsLookupFailed:
                return .dns
            case .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .cannotLoadFromNetwork,
                 .backgroundSessionWasDisconnected:
                return .connectivity
            case .cancelled:
                return .cancelled
            default:
                return .other
            }
        }
        guard let fetchError = error as? FetchError else { return .other }
        switch fetchError {
        case .httpStatus(let statusCode):
            if statusCode == 408 { return .timeout }
            if statusCode == 429 { return .rateLimited }
            if (500...599).contains(statusCode) { return .httpServer }
            return .httpClient
        case .invalidResponse:
            return .invalidResponse
        case .emptyBody:
            return .emptyBody
        case .lengthMismatch, .invalidContentRange:
            return .rangeValidation
        case .checksumMismatch:
            return .checksum
        }
    }

    private func emitEvent(
        url: URL,
        start: Date,
        byteCount: Int,
        attemptCount: Int,
        outcome: RetryOutcome,
        errorCategory: FetchErrorCategory?
    ) async {
        guard let eventHandler else { return }
        await eventHandler(FetchEvent(
            url: url,
            duration: max(0, retryClock.now().timeIntervalSince(start)),
            byteCount: byteCount,
            attemptCount: attemptCount,
            retryCount: max(0, attemptCount - 1),
            retryOutcome: outcome,
            errorCategory: errorCategory
        ))
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
