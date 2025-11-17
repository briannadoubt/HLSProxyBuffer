import Foundation

public struct HLSManifestFetcher: Sendable, HLSManifestSource {
    public struct RetryPolicy: Sendable, Equatable {
        public static let `default` = RetryPolicy(maxAttempts: 2, retryDelay: 0.5)

        public let maxAttempts: Int
        public let retryDelay: TimeInterval

        public init(maxAttempts: Int, retryDelay: TimeInterval) {
            self.maxAttempts = max(1, maxAttempts)
            self.retryDelay = retryDelay
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
    private let logger: Logger

    public init(
        url: URL,
        session: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        logger: Logger = DefaultLogger()
    ) {
        self.url = url
        self.session = session
        self.retryPolicy = retryPolicy
        self.logger = logger
    }

    public func fetchManifest() async throws -> String {
        try await fetchManifest(from: url)
    }

    public func fetchManifest(from url: URL) async throws -> String {
        try await fetchManifest(from: url, allowInsecure: false)
    }

    public func fetchManifest(from url: URL, allowInsecure: Bool, requestTimeout: TimeInterval? = nil) async throws -> String {
        guard allowInsecure || url.scheme?.lowercased() == "https" else {
            throw FetchError.insecureScheme
        }

        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                try Task.checkCancellation()
                return try await fetchOnce(from: url, requestTimeout: requestTimeout)
            } catch let fetchError as FetchError where !fetchError.isRetryable {
                throw fetchError
            } catch {
                lastError = error
                logger.log("Manifest fetch failed (attempt \(attempt)): \(error)", category: .manifest)
                if attempt < retryPolicy.maxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(retryPolicy.retryDelay * 1_000_000_000))
                }
            }
        }

        throw FetchError.retryExhausted(lastError ?? FetchError.emptyBody)
    }

    private func fetchOnce(from url: URL, requestTimeout: TimeInterval?) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout ?? 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse(response)
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

        return string
    }
}
