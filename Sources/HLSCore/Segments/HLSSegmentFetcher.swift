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
        case invalidContentRange(String?)
        case checksumMismatch
    }

    private var session: URLSession
    private var networkPolicy: HLSOriginNetworkPolicy
    private let managesSession: Bool
    private var validationPolicy: ValidationPolicy
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
    }

    public init(
        session: URLSession? = nil,
        validationPolicy: ValidationPolicy = .init(),
        networkPolicy: HLSOriginNetworkPolicy = .default
    ) {
        self.session = session ?? networkPolicy.makeURLSession()
        self.networkPolicy = networkPolicy
        self.managesSession = session == nil
        self.validationPolicy = validationPolicy
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
        if let existing = inFlight[key] {
            let data = try await existing.task.value
            try Task.checkCancellation()
            return data
        }

        let id = UUID()
        let task = Task { try await performFetch(from: url, metadata: metadata) }
        inFlight[key] = InFlight(id: id, task: task)
        do {
            let data = try await task.value
            removeInFlight(key: key, id: id)
            try Task.checkCancellation()
            return data
        } catch {
            removeInFlight(key: key, id: id)
            throw error
        }
    }

    private func removeInFlight(key: FetchKey, id: UUID) {
        guard inFlight[key]?.id == id else { return }
        inFlight.removeValue(forKey: key)
    }

    private func performFetch(from url: URL, metadata: HLSSegment?) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = networkPolicy.requestTimeout
        if let range = metadata?.byteRange {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }

        let start = Date()
        let (receivedData, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode)
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

        let metrics = FetchMetrics(url: url, byteCount: data.count, duration: duration)
        latestMetricsValue = metrics
        if let metricsHandler {
            await metricsHandler(metrics)
        }

        return data
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
