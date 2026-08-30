import Foundation
import LocalProxy

/// A deterministic loopback HLS origin for the primary feed demo and its UI
/// qualifications. Runtime controls make adverse network and cache scenarios
/// reproducible without depending on the public internet.
final class FeedDemoFixtureOrigin: Sendable {
    struct NetworkProfile: Equatable, Sendable {
        var responseDelay: Duration
        var bytesPerSecond: Int?

        init(responseDelay: Duration = .zero, bytesPerSecond: Int? = nil) {
            self.responseDelay = max(.zero, responseDelay)
            self.bytesPerSecond = bytesPerSecond.map { max(1, $0) }
        }

        static let unconstrained = Self()
        static let poor = Self(responseDelay: .milliseconds(150), bytesPerSecond: 96 * 1_024)
    }

    struct Fault: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case serviceUnavailable
        }

        let path: String
        let attempts: ClosedRange<Int>
        let action: Action

        init(path: String, attempts: ClosedRange<Int>, action: Action) {
            self.path = path.hasPrefix("/") ? path : "/\(path)"
            self.attempts = attempts
            self.action = action
        }
    }

    struct RequestRecord: Codable, Equatable, Sendable {
        let sequence: UInt64
        let method: String
        let path: String
        let feedItemID: String?
        let attempt: Int
        let statusCode: Int
        let responseBytes: Int
        let requestedRange: String?
        let wasConditional: Bool
        let wasOffline: Bool
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let requestCount: Int
        let responseByteCount: Int
        let conditionalRequestCount: Int
        let notModifiedCount: Int
        let failureCount: Int
        let offlineRequestCount: Int
        let activeRequestCount: Int
        let maximumActiveRequestCount: Int
        let requestsByPath: [String: Int]
        let bytesByPath: [String: Int]
        let records: [RequestRecord]

        static let empty = Self(
            requestCount: 0,
            responseByteCount: 0,
            conditionalRequestCount: 0,
            notModifiedCount: 0,
            failureCount: 0,
            offlineRequestCount: 0,
            activeRequestCount: 0,
            maximumActiveRequestCount: 0,
            requestsByPath: [:],
            bytesByPath: [:],
            records: []
        )
    }

    private enum StartError: Error {
        case timedOut
    }

    private struct Resource: Sendable {
        let data: Data
        let contentType: String
        let etag: String
        let feedItemID: String?
    }

    private actor ControlPlane {
        private static let maximumRecordCount = 2_048

        private let resources: [String: Resource]
        private var profile = NetworkProfile.unconstrained
        private var faults: [Fault] = []
        private var isOffline = false
        private var nextSequence: UInt64 = 1
        private var attemptsByPath: [String: Int] = [:]
        private var requestCount = 0
        private var responseByteCount = 0
        private var conditionalRequestCount = 0
        private var notModifiedCount = 0
        private var failureCount = 0
        private var offlineRequestCount = 0
        private var activeRequestCount = 0
        private var maximumActiveRequestCount = 0
        private var requestsByPath: [String: Int] = [:]
        private var bytesByPath: [String: Int] = [:]
        private var records: [RequestRecord] = []

        init(resources: [String: Resource]) {
            self.resources = resources
        }

        func setNetworkProfile(_ profile: NetworkProfile) {
            self.profile = profile
        }

        func setFaults(_ faults: [Fault]) {
            self.faults = faults
            attemptsByPath.removeAll(keepingCapacity: true)
        }

        func setOffline(_ isOffline: Bool) {
            self.isOffline = isOffline
        }

        func resetRequestAccounting(resetFaultAttempts: Bool) {
            nextSequence = 1
            requestCount = 0
            responseByteCount = 0
            conditionalRequestCount = 0
            notModifiedCount = 0
            failureCount = 0
            offlineRequestCount = 0
            activeRequestCount = 0
            maximumActiveRequestCount = 0
            requestsByPath.removeAll(keepingCapacity: true)
            bytesByPath.removeAll(keepingCapacity: true)
            records.removeAll(keepingCapacity: true)
            if resetFaultAttempts {
                attemptsByPath.removeAll(keepingCapacity: true)
            }
        }

        func snapshot() -> Snapshot {
            Snapshot(
                requestCount: requestCount,
                responseByteCount: responseByteCount,
                conditionalRequestCount: conditionalRequestCount,
                notModifiedCount: notModifiedCount,
                failureCount: failureCount,
                offlineRequestCount: offlineRequestCount,
                activeRequestCount: activeRequestCount,
                maximumActiveRequestCount: maximumActiveRequestCount,
                requestsByPath: requestsByPath,
                bytesByPath: bytesByPath,
                records: records
            )
        }

        func response(for request: HTTPRequest) async -> HTTPResponse {
            let attempt = attemptsByPath[request.path, default: 0] + 1
            attemptsByPath[request.path] = attempt
            let sequence = nextSequence
            nextSequence &+= 1
            requestCount += 1
            requestsByPath[request.path, default: 0] += 1
            activeRequestCount += 1
            maximumActiveRequestCount = max(maximumActiveRequestCount, activeRequestCount)

            let wasConditional = request.headers["if-none-match"] != nil
                || request.headers["if-modified-since"] != nil
            if wasConditional {
                conditionalRequestCount += 1
            }

            let offlineAtStart = isOffline
            let response: HTTPResponse
            if offlineAtStart {
                offlineRequestCount += 1
                response = HTTPResponse(
                    status: .serviceUnavailable,
                    headers: ["Cache-Control": "no-store", "Retry-After": "0"]
                )
            } else if let fault = faults.first(where: {
                $0.path == request.path && $0.attempts.contains(attempt)
            }) {
                switch fault.action {
                case .serviceUnavailable:
                    response = HTTPResponse(
                        status: .serviceUnavailable,
                        headers: ["Cache-Control": "no-store", "Retry-After": "0"]
                    )
                }
            } else {
                response = Self.regularResponse(for: request, resources: resources)
            }

            let activeProfile = profile
            if activeProfile.responseDelay > .zero {
                try? await Task.sleep(for: activeProfile.responseDelay)
            }
            if let bytesPerSecond = activeProfile.bytesPerSecond,
               !response.body.isEmpty {
                let seconds = Double(response.body.count) / Double(bytesPerSecond)
                if seconds > 0 {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }

            activeRequestCount = max(0, activeRequestCount - 1)
            let byteCount = request.method == .head ? 0 : response.body.count
            responseByteCount += byteCount
            bytesByPath[request.path, default: 0] += byteCount
            if response.status == .notModified { notModifiedCount += 1 }
            if response.status.rawValue >= 400 { failureCount += 1 }
            append(RequestRecord(
                sequence: sequence,
                method: request.method.rawValue,
                path: request.path,
                feedItemID: resources[request.path]?.feedItemID,
                attempt: attempt,
                statusCode: response.status.rawValue,
                responseBytes: byteCount,
                requestedRange: request.headers["range"],
                wasConditional: wasConditional,
                wasOffline: offlineAtStart
            ))
            return response
        }

        private func append(_ record: RequestRecord) {
            if records.count == Self.maximumRecordCount {
                records.removeFirst()
            }
            records.append(record)
        }

        private static func regularResponse(
            for request: HTTPRequest,
            resources: [String: Resource]
        ) -> HTTPResponse {
            guard request.method == .get || request.method == .head,
                  let resource = resources[request.path]
            else {
                return HTTPResponse(
                    status: request.method == .post ? .methodNotAllowed : .notFound,
                    headers: ["Cache-Control": "no-store"]
                )
            }
            let validatorMatches = request.headers["if-none-match"] == resource.etag
                || request.headers["if-modified-since"] == FeedDemoFixtureOrigin.lastModified
            if validatorMatches {
                return HTTPResponse(
                    status: .notModified,
                    headers: validationHeaders(for: resource)
                )
            }
            if let rangeHeader = request.headers["range"] {
                guard let range = FeedDemoFixtureOrigin.parseRange(
                    rangeHeader,
                    dataCount: resource.data.count
                ) else {
                    return HTTPResponse(
                        status: .rangeNotSatisfiable,
                        headers: ["Content-Range": "bytes */\(resource.data.count)"]
                    )
                }
                var headers = validationHeaders(for: resource)
                headers["Content-Type"] = resource.contentType
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(resource.data.count)"
                return HTTPResponse(
                    status: .partialContent,
                    headers: headers,
                    body: request.method == .head
                        ? Data()
                        : resource.data.subdata(in: range.lowerBound..<(range.upperBound + 1))
                )
            }
            var headers = validationHeaders(for: resource)
            headers["Content-Type"] = resource.contentType
            return HTTPResponse(
                status: .ok,
                headers: headers,
                body: request.method == .head ? Data() : resource.data
            )
        }

        private static func validationHeaders(for resource: Resource) -> [String: String] {
            var headers = [
                "Accept-Ranges": "bytes",
                "Cache-Control": "public, max-age=60",
                "ETag": resource.etag,
                "Last-Modified": FeedDemoFixtureOrigin.lastModified,
            ]
            if let feedItemID = resource.feedItemID {
                headers["X-HLS-Fixture-Item"] = feedItemID
            }
            return headers
        }
    }

    private static let lastModified = "Wed, 26 Aug 2026 00:00:00 GMT"

    private let server: ProxyServer
    private let controlPlane: ControlPlane

    init() throws {
        let controlPlane = ControlPlane(resources: try Self.loadResources())
        let router = ProxyRouter()
        router.register(path: "/*") { request in
            await controlPlane.response(for: request)
        }
        self.controlPlane = controlPlane
        self.server = ProxyServer(router: router)
    }

    var baseURL: URL? { server.baseURL }

    func start() async throws -> URL {
        try server.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let baseURL, baseURL.port != 0 {
                return baseURL
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw StartError.timedOut
    }

    func stop() {
        server.stop()
    }

    func setNetworkProfile(_ profile: NetworkProfile) async {
        await controlPlane.setNetworkProfile(profile)
    }

    func setFaults(_ faults: [Fault]) async {
        await controlPlane.setFaults(faults)
    }

    func setOffline(_ isOffline: Bool) async {
        await controlPlane.setOffline(isOffline)
    }

    func resetRequestAccounting(resetFaultAttempts: Bool = true) async {
        await controlPlane.resetRequestAccounting(resetFaultAttempts: resetFaultAttempts)
    }

    func snapshot() async -> Snapshot {
        await controlPlane.snapshot()
    }

    private static func loadResources() throws -> [String: Resource] {
        guard let resourceRoot = resourceBundle.resourceURL?.appendingPathComponent(
            "Fixtures",
            isDirectory: true
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = resourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else {
            throw CocoaError(.fileNoSuchFile)
        }

        var result: [String: Resource] = [:]
        for case let fileURL as URL in enumerator {
            // The real corpus has its own file-backed catalog. Never preload it
            // into the explicitly synthetic fixture origin.
            if fileURL.standardizedFileURL == root.appendingPathComponent("real").standardizedFileURL {
                enumerator.skipDescendants()
                continue
            }
            let resolvedFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            let values = try resolvedFileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rootComponents = root.pathComponents
            let fileComponents = resolvedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { continue }
            let relativeComponents = fileComponents.dropFirst(rootComponents.count)
            guard !relativeComponents.isEmpty else { continue }
            let relativePath = "/" + relativeComponents.joined(separator: "/")
            let data = try Data(contentsOf: resolvedFileURL)
            result[relativePath] = Resource(
                data: data,
                contentType: contentType(for: resolvedFileURL.pathExtension),
                etag: etag(for: data),
                feedItemID: nil
            )
        }

        for item in FeedDemoFixtureCatalog.shortItems {
            let sourcePrefix = "/\(item.sourceFixture)/"
            let destinationPrefix = "/feed/\(item.fixtureID)/"
            for (path, source) in result where path.hasPrefix(sourcePrefix) {
                let suffix = path.dropFirst(sourcePrefix.count)
                let aliasPath = destinationPrefix + suffix
                let data = path.hasSuffix("/playlist.m3u8")
                    ? shortPlaylist(item: item)
                    : source.data
                result[aliasPath] = Resource(
                    data: data,
                    contentType: source.contentType,
                    etag: etag(for: data),
                    feedItemID: item.fixtureID
                )
            }
        }
        return result
    }

    private static func shortPlaylist(item: FeedDemoFixtureCatalog.ShortItem) -> Data {
        var lines = [
            "#EXTM3U",
            "# HLSProxyBuffer fixture \(item.fixtureID)",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:1",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for index in 0..<item.segmentCount {
            lines.append("#EXTINF:1.000000,")
            lines.append(String(format: "segment-%03d.m4s", index))
        }
        lines.append("#EXT-X-ENDLIST")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        .module
#else
        .main
#endif
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "mp4", "m4s": "video/mp4"
        case "md": "text/markdown; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    private static func etag(for data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\"\(data.count)-\(String(hash, radix: 16))\""
    }

    private static func parseRange(_ value: String, dataCount: Int) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes="), dataCount > 0 else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let lower = Int(bounds[0]), lower >= 0, lower < dataCount
        else {
            return nil
        }
        let requestedUpper = bounds[1].isEmpty ? dataCount - 1 : Int(bounds[1])
        guard let requestedUpper, requestedUpper >= lower else { return nil }
        return lower...min(requestedUpper, dataCount - 1)
    }
}
