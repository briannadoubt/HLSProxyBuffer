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

        public init(enforceByteRangeLength: Bool = true, checksum: Checksum? = nil) {
            self.enforceByteRangeLength = enforceByteRangeLength
            self.checksum = checksum
        }
    }

    public struct FetchMetrics: Sendable {
        public let url: URL
        public let byteCount: Int
        public let duration: TimeInterval
    }

    public enum FetchError: Error {
        case invalidResponse
        case httpStatus(Int)
        case emptyBody
        case lengthMismatch(expected: Int, actual: Int)
        case checksumMismatch
    }

    private let session: URLSession
    private var validationPolicy: ValidationPolicy
    private var metricsHandler: (@Sendable (FetchMetrics) async -> Void)?
    private var latestMetricsValue: FetchMetrics?

    public init(
        session: URLSession = .shared,
        validationPolicy: ValidationPolicy = .init()
    ) {
        self.session = session
        self.validationPolicy = validationPolicy
    }

    public func updateValidationPolicy(_ policy: ValidationPolicy) {
        validationPolicy = policy
    }

    public func fetchSegment(_ segment: HLSSegment) async throws -> Data {
        try await fetchSegment(from: segment.url, metadata: segment)
    }

    public func fetchSegment(from url: URL) async throws -> Data {
        try await fetchSegment(from: url, metadata: nil)
    }

    public func onMetrics(_ handler: (@Sendable (FetchMetrics) async -> Void)?) {
        metricsHandler = handler
    }

    public func latestMetrics() -> FetchMetrics? {
        latestMetricsValue
    }

    private func fetchSegment(from url: URL, metadata: HLSSegment?) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

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

        try validate(data: data, metadata: metadata)

        let metrics = FetchMetrics(url: url, byteCount: data.count, duration: duration)
        latestMetricsValue = metrics
        if let metricsHandler {
            await metricsHandler(metrics)
        }

        return data
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
