import Foundation

public struct HLSManifestFetcher: Sendable, HLSManifestSource {
    public struct Validation: Equatable, Sendable {
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

    public enum ValidatedManifest: Equatable, Sendable {
        case modified(String, validation: Validation)
        case notModified(validation: Validation)
    }

    public struct RetryPolicy: Sendable, Equatable {
        public static let `default` = RetryPolicy(maxAttempts: 3, retryDelay: 0.25)

        public let maxAttempts: Int
        public let retryDelay: TimeInterval
        public let maximumRetryDelay: TimeInterval
        public let jitterRatio: Double

        public init(
            maxAttempts: Int,
            retryDelay: TimeInterval,
            maximumRetryDelay: TimeInterval = 8,
            jitterRatio: Double = 0.2
        ) {
            self.maxAttempts = max(1, maxAttempts)
            self.retryDelay = max(0, retryDelay)
            self.maximumRetryDelay = max(self.retryDelay, maximumRetryDelay)
            self.jitterRatio = min(max(0, jitterRatio), 1)
        }
    }

    public enum FetchError: Error, CustomStringConvertible {
        case insecureScheme
        case invalidResponse(URLResponse?)
        case httpStatus(Int)
        case emptyBody
        case utf8Decoding
        case retryExhausted(Error)

        var isRetryable: Bool {
            switch self {
            case .utf8Decoding, .insecureScheme:
                return false
            case .httpStatus(let code):
                return code == 408 || code == 429 || (500...599).contains(code)
            default:
                return true
            }
        }

        public var description: String {
            switch self {
            case .insecureScheme:
                return "Only HTTPS manifests are permitted."
            case .invalidResponse(let response):
                return "Unexpected response: \(String(describing: response))."
            case .httpStatus(let code):
                return "HTTP error \(code)."
            case .emptyBody:
                return "Manifest body was empty."
            case .utf8Decoding:
                return "Manifest data was not valid UTF-8."
            case .retryExhausted(let error):
                return "All retry attempts failed: \(error.localizedDescription)"
            }
        }
    }

    private let url: URL
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let networkPolicy: HLSOriginNetworkPolicy
    private let logger: Logger

    public init(
        url: URL,
        session: URLSession? = nil,
        retryPolicy: RetryPolicy = .default,
        networkPolicy: HLSOriginNetworkPolicy = .default,
        logger: Logger = DefaultLogger()
    ) {
        self.url = url
        self.session = session ?? networkPolicy.makeURLSession()
        self.retryPolicy = retryPolicy
        self.networkPolicy = networkPolicy
        self.logger = logger
    }

    public func fetchManifest() async throws -> String {
        try await fetchManifest(from: url)
    }

    public func fetchManifest(from url: URL) async throws -> String {
        try await fetchManifest(from: url, allowInsecure: false)
    }

    public func fetchManifest(from url: URL, allowInsecure: Bool, requestTimeout: TimeInterval? = nil) async throws -> String {
        let result = try await fetchValidatedManifest(
            from: url,
            allowInsecure: allowInsecure,
            requestTimeout: requestTimeout
        )
        guard case .modified(let manifest, _) = result else {
            throw FetchError.invalidResponse(nil)
        }
        return manifest
    }

    /// Fetches a manifest with optional conditional validators. A 304 response
    /// is represented explicitly so the caller can reuse its persisted bytes.
    public func fetchValidatedManifest(
        from url: URL,
        allowInsecure: Bool,
        requestTimeout: TimeInterval? = nil,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil
    ) async throws -> ValidatedManifest {
        guard allowInsecure || url.scheme?.lowercased() == "https" else {
            throw FetchError.insecureScheme
        }

        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                try Task.checkCancellation()
                return try await fetchOnce(
                    from: url,
                    requestTimeout: requestTimeout,
                    ifNoneMatch: ifNoneMatch,
                    ifModifiedSince: ifModifiedSince
                )
            } catch let fetchError as FetchError where !fetchError.isRetryable {
                throw fetchError
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
                logger.log("Manifest fetch failed (attempt \(attempt)): \(error)", category: .manifest)
                if attempt < retryPolicy.maxAttempts {
                    let exponential = min(
                        retryPolicy.maximumRetryDelay,
                        retryPolicy.retryDelay * pow(2, Double(attempt - 1))
                    )
                    let jitter = exponential * retryPolicy.jitterRatio * Double.random(in: -1...1)
                    let delay = max(0, exponential + jitter)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw FetchError.retryExhausted(lastError ?? FetchError.emptyBody)
    }

    private func fetchOnce(
        from url: URL,
        requestTimeout: TimeInterval?,
        ifNoneMatch: String?,
        ifModifiedSince: String?
    ) async throws -> ValidatedManifest {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout ?? networkPolicy.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let ifNoneMatch = Self.safeValidator(ifNoneMatch) {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let ifModifiedSince = Self.safeValidator(ifModifiedSince) {
            request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse(response)
        }

        let validation = Validation(
            eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
            lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified"),
            maximumAge: Self.maximumAge(
                from: httpResponse.value(forHTTPHeaderField: "Cache-Control")
            ),
            allowsStorage: Self.allowsStorage(
                cacheControl: httpResponse.value(forHTTPHeaderField: "Cache-Control")
            )
        )
        if httpResponse.statusCode == 304 {
            return .notModified(validation: validation)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FetchError.httpStatus(httpResponse.statusCode)
        }

        guard !data.isEmpty else {
            throw FetchError.emptyBody
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw FetchError.utf8Decoding
        }

        return .modified(string, validation: validation)
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
}
