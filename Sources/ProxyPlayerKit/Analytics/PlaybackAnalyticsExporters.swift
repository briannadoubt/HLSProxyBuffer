import Compression
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OSLog

/// Deterministic wire encodings shared by the reference sinks.
public enum PlaybackAnalyticsExportCodec {
    public static func encode(_ record: PlaybackAnalyticsRecord) throws -> Data {
        try encoder().encode(record)
    }

    public static func encode(_ batch: PlaybackAnalyticsBatch) throws -> Data {
        try encoder().encode(batch)
    }

    /// Encodes one self-contained record per line, including a final newline.
    public static func encodeJSONLines(_ batch: PlaybackAnalyticsBatch) throws -> Data {
        guard !batch.records.isEmpty else { return Data() }
        var result = Data()
        for record in batch.records {
            result.append(try encode(record))
            result.append(0x0A)
        }
        return result
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A bounded reference sink for tests, previews, and small integrations.
public actor InMemoryPlaybackAnalyticsSink: PlaybackAnalyticsSink {
    public struct Configuration: Equatable, Sendable {
        public let maximumRecordCount: Int
        public let maximumBatchCount: Int

        public init(maximumRecordCount: Int = 1_024, maximumBatchCount: Int = 64) {
            self.maximumRecordCount = min(max(1, maximumRecordCount), 65_536)
            self.maximumBatchCount = min(max(1, maximumBatchCount), 4_096)
        }
    }

    public struct Snapshot: Equatable, Codable, Sendable {
        public let retainedRecordCount: Int
        public let retainedBatchCount: Int
        public let acceptedRecordCount: UInt64
        public let acceptedBatchCount: UInt64
        public let evictedRecordCount: UInt64
        public let evictedBatchCount: UInt64
    }

    public private(set) var records: [PlaybackAnalyticsRecord] = []
    public private(set) var batches: [PlaybackAnalyticsBatch] = []
    public var snapshot: Snapshot {
        .init(
            retainedRecordCount: records.count,
            retainedBatchCount: batches.count,
            acceptedRecordCount: acceptedRecordCount,
            acceptedBatchCount: acceptedBatchCount,
            evictedRecordCount: evictedRecordCount,
            evictedBatchCount: evictedBatchCount
        )
    }

    private let configuration: Configuration
    private var acceptedRecordCount: UInt64 = 0
    private var acceptedBatchCount: UInt64 = 0
    private var evictedRecordCount: UInt64 = 0
    private var evictedBatchCount: UInt64 = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func send(_ batch: PlaybackAnalyticsBatch) async throws {
        acceptedBatchCount = Self.saturatingAdd(acceptedBatchCount, 1)
        acceptedRecordCount = Self.saturatingAdd(
            acceptedRecordCount,
            UInt64(batch.records.count)
        )
        batches.append(batch)
        records.append(contentsOf: batch.records)

        if batches.count > configuration.maximumBatchCount {
            let overflow = batches.count - configuration.maximumBatchCount
            batches.removeFirst(overflow)
            evictedBatchCount = Self.saturatingAdd(evictedBatchCount, UInt64(overflow))
        }
        if records.count > configuration.maximumRecordCount {
            let overflow = records.count - configuration.maximumRecordCount
            records.removeFirst(overflow)
            evictedRecordCount = Self.saturatingAdd(evictedRecordCount, UInt64(overflow))
        }
    }

    public func reset() {
        records.removeAll(keepingCapacity: false)
        batches.removeAll(keepingCapacity: false)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

/// A rotating, deterministic JSON Lines sink for local inspection and import.
public actor JSONLinesPlaybackAnalyticsSink: PlaybackAnalyticsSink {
    public struct Configuration: Equatable, Sendable {
        public let maximumFileBytes: Int
        public let maximumArchiveCount: Int

        public init(
            maximumFileBytes: Int = 4 * 1_024 * 1_024,
            maximumArchiveCount: Int = 2
        ) {
            self.maximumFileBytes = min(max(256, maximumFileBytes), 64 * 1_024 * 1_024)
            self.maximumArchiveCount = min(max(0, maximumArchiveCount), 16)
        }
    }

    public enum Failure: Error, Equatable, Sendable,
        PlaybackAnalyticsRetryClassifyingError {
        case fileURLRequired
        case payloadExceedsFileLimit(limit: Int, actual: Int)

        public var retryDisposition: PlaybackAnalyticsRetryDisposition { .permanent }
    }

    public struct Snapshot: Equatable, Codable, Sendable {
        public let fileBytes: Int
        public let writtenRecordCount: UInt64
        public let writtenBatchCount: UInt64
        public let rotationCount: UInt64
    }

    public let fileURL: URL
    public var snapshot: Snapshot {
        .init(
            fileBytes: Self.fileSize(at: fileURL),
            writtenRecordCount: writtenRecordCount,
            writtenBatchCount: writtenBatchCount,
            rotationCount: rotationCount
        )
    }

    private let configuration: Configuration
    private var writtenRecordCount: UInt64 = 0
    private var writtenBatchCount: UInt64 = 0
    private var rotationCount: UInt64 = 0

    public init(fileURL: URL, configuration: Configuration = .init()) throws {
        guard fileURL.isFileURL else { throw Failure.fileURLRequired }
        self.fileURL = fileURL.standardizedFileURL
        self.configuration = configuration
        try Self.prepareFile(at: self.fileURL)
    }

    public func send(_ batch: PlaybackAnalyticsBatch) async throws {
        let encoded = try PlaybackAnalyticsExportCodec.encodeJSONLines(batch)
        guard !encoded.isEmpty else { return }
        guard encoded.count <= configuration.maximumFileBytes else {
            throw Failure.payloadExceedsFileLimit(
                limit: configuration.maximumFileBytes,
                actual: encoded.count
            )
        }
        if Self.fileSize(at: fileURL) > configuration.maximumFileBytes - encoded.count {
            try rotate()
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded)
        try handle.synchronize()
        writtenRecordCount = Self.saturatingAdd(
            writtenRecordCount,
            UInt64(batch.records.count)
        )
        writtenBatchCount = Self.saturatingAdd(writtenBatchCount, 1)
    }

    private func rotate() throws {
        let manager = FileManager.default
        if configuration.maximumArchiveCount == 0 {
            try Data().write(to: fileURL, options: .atomic)
            rotationCount = Self.saturatingAdd(rotationCount, 1)
            return
        }
        for index in stride(
            from: configuration.maximumArchiveCount,
            through: 1,
            by: -1
        ) {
            let destination = archiveURL(index)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            let source = index == 1 ? fileURL : archiveURL(index - 1)
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: destination)
            }
        }
        try Self.prepareFile(at: fileURL)
        rotationCount = Self.saturatingAdd(rotationCount, 1)
    }

    private func archiveURL(_ index: Int) -> URL {
        URL(fileURLWithPath: fileURL.path + ".\(index)")
    }

    private static func prepareFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
    }

    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return max(0, (attributes?[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

/// Emits aggregate batch metadata to unified logging and a signpost event.
/// Record payloads, identifiers, dimensions, and credentials are never logged.
public actor OSLogPlaybackAnalyticsSink: PlaybackAnalyticsSink {
    private let logger: Logger
    private let signposter: OSSignposter

    public init(subsystem: String, category: String = "PlaybackAnalytics") {
        let logger = Logger(subsystem: subsystem, category: category)
        self.logger = logger
        signposter = OSSignposter(logger: logger)
    }

    public func send(_ batch: PlaybackAnalyticsBatch) async throws {
        let eventCount = batch.records.reduce(into: 0) { count, record in
            if case .event = record { count += 1 }
        }
        let summaryCount = batch.records.count - eventCount
        signposter.emitEvent(
            "PlaybackAnalyticsBatch",
            "records=\(batch.records.count, privacy: .public) events=\(eventCount, privacy: .public) summaries=\(summaryCount, privacy: .public)"
        )
        logger.info(
            "Accepted analytics batch: records=\(batch.records.count, privacy: .public) events=\(eventCount, privacy: .public) summaries=\(summaryCount, privacy: .public)"
        )
    }
}

/// A bounded HTTPS-only batch sink backed by an application-injected session.
public struct HTTPSPlaybackAnalyticsSink: PlaybackAnalyticsSink {
    public struct EphemeralAuthorization: Sendable {
        private let provider: @Sendable () async throws -> String?

        /// The provider runs for every request. Return the complete ephemeral
        /// `Authorization` header value, or `nil` for no authorization.
        public init(provider: @escaping @Sendable () async throws -> String?) {
            self.provider = provider
        }

        fileprivate func value() async throws -> String? {
            try await provider()
        }
    }

    public struct Configuration: Sendable {
        public let endpoint: URL
        public let maximumPayloadBytes: Int
        public let maximumRecordCount: Int
        public let compressionThresholdBytes: Int?
        public let timeout: TimeInterval
        public let authorization: EphemeralAuthorization?

        public init(
            endpoint: URL,
            maximumPayloadBytes: Int = 256 * 1_024,
            maximumRecordCount: Int = 256,
            compressionThresholdBytes: Int? = 4 * 1_024,
            timeout: TimeInterval = 15,
            authorization: EphemeralAuthorization? = nil
        ) throws {
            guard endpoint.scheme?.lowercased() == "https",
                  endpoint.host != nil,
                  endpoint.user == nil,
                  endpoint.password == nil
            else {
                throw Failure.httpsEndpointRequired
            }
            self.endpoint = endpoint
            let boundedPayloadBytes = min(
                max(1_024, maximumPayloadBytes),
                4 * 1_024 * 1_024
            )
            self.maximumPayloadBytes = boundedPayloadBytes
            self.maximumRecordCount = min(max(1, maximumRecordCount), 4_096)
            self.compressionThresholdBytes = compressionThresholdBytes.map {
                min(max(256, $0), boundedPayloadBytes)
            }
            self.timeout = min(max(1, timeout.isFinite ? timeout : 15), 120)
            self.authorization = authorization
        }
    }

    public enum Failure: Error, Equatable, Sendable,
        PlaybackAnalyticsRetryClassifyingError {
        case httpsEndpointRequired
        case tooManyRecords(limit: Int, actual: Int)
        case payloadTooLarge(limit: Int, actual: Int)
        case invalidAuthorization
        case insecureRedirect
        case invalidResponse
        case httpStatus(Int)
        case transport(URLError.Code)

        public var retryDisposition: PlaybackAnalyticsRetryDisposition {
            switch self {
            case .transport:
                .retryable
            case .invalidResponse:
                .retryable
            case .httpStatus(let status) where status == 408 || status == 425 || status == 429:
                .retryable
            case .httpStatus(let status) where (500...599).contains(status):
                .retryable
            default:
                .permanent
            }
        }
    }

    private let session: URLSession
    private let configuration: Configuration

    /// Inject a dedicated URLSession. Production callers should use an
    /// ephemeral configuration that is not shared with manifests or segments.
    public init(session: URLSession, configuration: Configuration) {
        self.session = session
        self.configuration = configuration
    }

    public func send(_ batch: PlaybackAnalyticsBatch) async throws {
        guard batch.records.count <= configuration.maximumRecordCount else {
            throw Failure.tooManyRecords(
                limit: configuration.maximumRecordCount,
                actual: batch.records.count
            )
        }
        let encoded = try PlaybackAnalyticsExportCodec.encode(batch)
        guard encoded.count <= configuration.maximumPayloadBytes else {
            throw Failure.payloadTooLarge(
                limit: configuration.maximumPayloadBytes,
                actual: encoded.count
            )
        }

        var body = encoded
        var contentEncoding: String?
        if let threshold = configuration.compressionThresholdBytes,
           encoded.count >= threshold,
           let compressed = Self.deflate(encoded),
           compressed.count < encoded.count {
            body = compressed
            contentEncoding = "deflate"
        }

        var request = URLRequest(
            url: configuration.endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: configuration.timeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(String(batch.records.count), forHTTPHeaderField: "X-Record-Count")
        if let contentEncoding {
            request.setValue(contentEncoding, forHTTPHeaderField: "Content-Encoding")
        }
        if let authorization = try await configuration.authorization?.value() {
            guard Self.isSafeHeaderValue(authorization) else {
                throw Failure.invalidAuthorization
            }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let response: URLResponse
        let redirectPolicy = HTTPSPlaybackAnalyticsRedirectPolicy()
        do {
            (_, response) = try await session.data(
                for: request,
                delegate: redirectPolicy
            )
        } catch let error as URLError {
            throw Failure.transport(error.code)
        }
        if redirectPolicy.rejectedInsecureRedirect {
            throw Failure.insecureRedirect
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.invalidResponse
        }
        guard http.url?.scheme?.lowercased() == "https" else {
            throw Failure.insecureRedirect
        }
        if (300...399).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"),
           let redirect = URL(string: location, relativeTo: http.url)?.absoluteURL,
           redirect.scheme?.lowercased() != "https" {
            throw Failure.insecureRedirect
        }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.httpStatus(http.statusCode)
        }
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var destination = Data(count: data.count)
        var scratch = Data(
            count: compression_encode_scratch_buffer_size(COMPRESSION_ZLIB)
        )
        let encodedSize = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                scratch.withUnsafeMutableBytes { scratchBuffer in
                    compression_encode_buffer(
                        destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        destinationBuffer.count,
                        sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        sourceBuffer.count,
                        scratchBuffer.baseAddress,
                        COMPRESSION_ZLIB
                    )
                }
            }
        }
        guard encodedSize > 0, encodedSize < data.count else { return nil }
        destination.removeSubrange(encodedSize...)
        return destination
    }

    private static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 8_192
            && value.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
    }
}

private final class HTTPSPlaybackAnalyticsRedirectPolicy: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejectedRedirect = false

    var rejectedInsecureRedirect: Bool {
        lock.withLock { rejectedRedirect }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            lock.withLock { rejectedRedirect = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
