import Foundation
import LocalProxy

/// A deterministic loopback HLS origin for the primary feed demo and its UI
/// qualifications. Runtime controls make adverse network and cache scenarios
/// reproducible without depending on the public internet.
final class FeedDemoFixtureOrigin: Sendable {
    struct Configuration: Sendable {
        enum Media: Equatable, Sendable { case real, synthetic }
        let media: Media
        let preferredPort: UInt16?
        let maximumConcurrentBodies: Int
        let maximumBodyBytes: Int

        init(
            media: Media,
            preferredPort: UInt16? = nil,
            maximumConcurrentBodies: Int = 4,
            maximumBodyBytes: Int = FeedDemoMediaLibrary.maximumResourceBytes
        ) {
            self.media = media
            self.preferredPort = preferredPort
            self.maximumConcurrentBodies = min(4, max(1, maximumConcurrentBodies))
            self.maximumBodyBytes = min(FeedDemoMediaLibrary.maximumResourceBytes, max(1, maximumBodyBytes))
        }

        static let realMedia = Self(media: .real, preferredPort: 49_374)
        static let synthetic = Self(media: .synthetic)
    }

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
        var cancelledRequestCount = 0
        var bodyBudget = FeedDemoBodyBudget.Snapshot()
        var corpusVersion: String?
        var originBinding: String?

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

    private struct Resource: Sendable {
        let data: Data?
        let fileURL: URL?
        let text: String?
        let byteCount: Int
        let contentType: String
        let etag: String
        let feedItemID: String?
        var isLive = false

        init(data: Data, contentType: String, etag: String, feedItemID: String?) {
            self.data = data
            self.fileURL = nil
            self.text = nil
            self.byteCount = data.count
            self.contentType = contentType
            self.etag = etag
            self.feedItemID = feedItemID
        }

        init(fileURL: URL, metadata: FeedDemoMediaLibrary.Resource, feedItemID: String?) {
            self.data = nil
            self.fileURL = fileURL
            self.text = nil
            self.byteCount = metadata.byteCount
            self.contentType = metadata.contentType
            self.etag = metadata.etag
            self.feedItemID = feedItemID
        }

        init(liveText: String, sequence: Int) {
            self.data = nil
            self.fileURL = nil
            self.text = liveText
            self.byteCount = liveText.utf8.count
            self.contentType = "application/vnd.apple.mpegurl"
            self.etag = "\"live-\(sequence)\""
            self.feedItemID = "continuous"
            self.isLive = true
        }

        func read(_ range: Range<Int>) throws -> Data {
            if let data { return data.subdata(in: range) }
            if let text {
                let data = Data(text.utf8)
                return range == 0..<data.count ? data : data.subdata(in: range)
            }
            guard let fileURL else { throw CocoaError(.fileReadUnknown) }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            guard let data = try handle.read(upToCount: range.count), data.count == range.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
    }

    private actor ControlPlane {
        private static let maximumRecordCount = 2_048

        private let resources: [String: Resource]
        private let library: FeedDemoMediaLibrary?
        private let bodyBudget: FeedDemoBodyBudget
        private let clock = ContinuousClock()
        private let liveStartedAt = ContinuousClock.now
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
        private var cancelledRequestCount = 0
        private var accountingGeneration: UInt64 = 0

        init(resources: [String: Resource], library: FeedDemoMediaLibrary?, configuration: Configuration) {
            self.resources = resources
            self.library = library
            self.bodyBudget = FeedDemoBodyBudget(
                bodyLimit: configuration.maximumConcurrentBodies,
                byteLimit: configuration.maximumBodyBytes
            )
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

        func resetRequestAccounting(resetFaultAttempts: Bool) async {
            accountingGeneration &+= 1
            nextSequence = 1
            requestCount = 0
            responseByteCount = 0
            conditionalRequestCount = 0
            notModifiedCount = 0
            failureCount = 0
            offlineRequestCount = 0
            cancelledRequestCount = 0
            maximumActiveRequestCount = activeRequestCount
            requestsByPath.removeAll(keepingCapacity: true)
            bytesByPath.removeAll(keepingCapacity: true)
            records.removeAll(keepingCapacity: true)
            if resetFaultAttempts {
                attemptsByPath.removeAll(keepingCapacity: true)
            }
            await bodyBudget.resetAccounting()
        }

        func snapshot() async -> Snapshot {
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
                records: records,
                cancelledRequestCount: cancelledRequestCount,
                bodyBudget: await bodyBudget.snapshot()
            )
        }

        func response(for request: HTTPRequest) async -> HTTPResponse {
            let generation = accountingGeneration
            // Unknown input must not create unbounded metric keys or retain
            // attacker-sized paths/headers in this local diagnostic fixture.
            let isKnownPath = resources[request.path] != nil
                || library.map { request.path == "/\($0.catalog.corpusVersion)/live/playlist.m3u8" } == true
            let accountingPath = isKnownPath ? request.path : "/unrecognized"
            let attempt = attemptsByPath[accountingPath, default: 0] + 1
            attemptsByPath[accountingPath] = attempt
            let sequence = nextSequence
            nextSequence &+= 1
            requestCount += 1
            requestsByPath[accountingPath, default: 0] += 1
            activeRequestCount += 1
            maximumActiveRequestCount = max(maximumActiveRequestCount, activeRequestCount)

            let wasConditional = request.headers["if-none-match"] != nil
                || request.headers["if-modified-since"] != nil
            if wasConditional {
                conditionalRequestCount += 1
            }

            let offlineAtStart = isOffline
            var response = HTTPResponse(status: .serviceUnavailable, headers: ["Cache-Control": "no-store"])
            do {
                let activeProfile = profile
                if activeProfile.responseDelay > .zero {
                    try await Task.sleep(for: activeProfile.responseDelay)
                }
                try Task.checkCancellation()
                if offlineAtStart {
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
                    response = try await Self.regularResponse(
                        for: request,
                        resource: resources[request.path] ?? liveResource(for: request.path),
                        bodyBudget: bodyBudget
                    )
                }
                if let bytesPerSecond = activeProfile.bytesPerSecond,
                   !response.body.isEmpty {
                    let seconds = Double(response.body.count) / Double(bytesPerSecond)
                    try await Task.sleep(for: .seconds(seconds))
                }
                try Task.checkCancellation()
            } catch {
                response = HTTPResponse(status: .serviceUnavailable, headers: ["Cache-Control": "no-store"])
            }

            activeRequestCount = max(0, activeRequestCount - 1)
            guard generation == accountingGeneration else { return response }
            if Task.isCancelled { cancelledRequestCount += 1 }
            if offlineAtStart { offlineRequestCount += 1 }
            let byteCount = request.method == .head ? 0 : response.body.count
            responseByteCount += byteCount
            bytesByPath[accountingPath, default: 0] += byteCount
            if response.status == .notModified { notModifiedCount += 1 }
            if response.status.rawValue >= 400 { failureCount += 1 }
            append(RequestRecord(
                sequence: sequence,
                method: request.method.rawValue,
                path: accountingPath,
                feedItemID: resources[request.path]?.feedItemID,
                attempt: attempt,
                statusCode: response.status.rawValue,
                responseBytes: byteCount,
                requestedRange: request.headers["range"].map { String($0.prefix(128)) },
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
            resource: Resource?,
            bodyBudget: FeedDemoBodyBudget
        ) async throws -> HTTPResponse {
            guard request.method == .get || request.method == .head,
                  let resource
            else {
                return HTTPResponse(
                    status: request.method == .post ? .methodNotAllowed : .notFound,
                    headers: ["Cache-Control": "no-store"]
                )
            }
            let validatorMatches: Bool
            if let tags = request.headers["if-none-match"] {
                validatorMatches = tags.split(separator: ",").contains {
                    let tag = $0.trimmingCharacters(in: .whitespaces)
                    return tag == "*" || tag == resource.etag || tag == "W/\(resource.etag)"
                }
            } else {
                validatorMatches = !resource.isLive
                    && request.headers["if-modified-since"] == FeedDemoFixtureOrigin.lastModified
            }
            if validatorMatches {
                return HTTPResponse(
                    status: .notModified,
                    headers: validationHeaders(for: resource)
                )
            }
            // Range semantics are defined only for GET (RFC 9110 §14.2).
            var headers = validationHeaders(for: resource)
            headers["Content-Type"] = resource.contentType
            let ifRange = request.headers["if-range"]
            let rangeAllowed = ifRange == nil || ifRange == resource.etag
                || (!resource.isLive && ifRange == FeedDemoFixtureOrigin.lastModified)
            if request.method == .get, rangeAllowed, let rangeHeader = request.headers["range"] {
                guard let range = FeedDemoFixtureOrigin.parseRange(
                    rangeHeader,
                    dataCount: resource.byteCount
                ) else {
                    return HTTPResponse(
                        status: .rangeNotSatisfiable,
                        headers: ["Content-Range": "bytes */\(resource.byteCount)"]
                    )
                }
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(resource.byteCount)"
                return try await bodyResponse(
                    resource: resource, range: range.lowerBound..<(range.upperBound + 1),
                    status: .partialContent, headers: headers, bodyBudget: bodyBudget
                )
            }
            if request.method == .head {
                return HTTPResponse(status: .ok, headers: headers, representationLength: resource.byteCount)
            }
            return try await bodyResponse(
                resource: resource, range: 0..<resource.byteCount, status: .ok,
                headers: headers, bodyBudget: bodyBudget
            )
        }

        private static func bodyResponse(
            resource: Resource, range: Range<Int>, status: HTTPResponse.Status,
            headers: [String: String], bodyBudget: FeedDemoBodyBudget
        ) async throws -> HTTPResponse {
            guard !range.isEmpty else { return HTTPResponse(status: status, headers: headers) }
            let permit = try await bodyBudget.acquire(bytes: range.count)
            try Task.checkCancellation()
            let data = try resource.read(range)
            await bodyBudget.didMaterialize()
            try Task.checkCancellation()
            return HTTPResponse(
                status: status, headers: headers, body: data,
                onBodyRelease: { withExtendedLifetime(permit) {} }
            )
        }

        private static func validationHeaders(for resource: Resource) -> [String: String] {
            var headers = [
                "Accept-Ranges": "bytes",
                "Cache-Control": resource.isLive ? "no-store" : "public, max-age=60",
                "ETag": resource.etag,
                "Last-Modified": FeedDemoFixtureOrigin.lastModified,
            ]
            if resource.isLive { headers.removeValue(forKey: "Last-Modified") }
            if let feedItemID = resource.feedItemID {
                headers["X-HLS-Fixture-Item"] = feedItemID
            }
            return headers
        }

        private func liveResource(for path: String) -> Resource? {
            guard let library,
                  path == "/\(library.catalog.corpusVersion)/live/playlist.m3u8"
            else { return nil }
            let elapsed = (clock.now - liveStartedAt).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            guard let window = FeedDemoLivePlaylist.make(library: library, elapsedSeconds: seconds) else { return nil }
            return Resource(liveText: window.text, sequence: window.sequence)
        }
    }

    private static let lastModified = "Wed, 26 Aug 2026 00:00:00 GMT"

    private let server: ProxyServer
    private let fallbackServer: ProxyServer?
    private let controlPlane: ControlPlane
    let library: FeedDemoMediaLibrary?
    let configuration: Configuration

    init(configuration: Configuration = .realMedia) throws {
        self.configuration = configuration
        let library: FeedDemoMediaLibrary? = configuration.media == .real ? try .bundled() : nil
        self.library = library
        let resources = try library.map(Self.loadRealResources) ?? Self.loadResources()
        let controlPlane = ControlPlane(resources: resources, library: library, configuration: configuration)
        let router = ProxyRouter()
        router.register(path: "/*") { request in
            await controlPlane.response(for: request)
        }
        self.controlPlane = controlPlane
        self.server = ProxyServer(configuration: .init(port: configuration.preferredPort, maximumConnectionCount: 64), router: router)
        self.fallbackServer = configuration.preferredPort == nil ? nil
            : ProxyServer(configuration: .init(maximumConnectionCount: 64), router: router)
    }

    var baseURL: URL? { server.baseURL ?? fallbackServer?.baseURL }

    var usesFallbackPort: Bool { configuration.preferredPort != nil && server.baseURL == nil && fallbackServer?.baseURL != nil }

    func start() async throws -> URL {
        do {
            return try await server.startAndWait()
        } catch {
            try Task.checkCancellation()
            guard let fallbackServer else { throw error }
            return try await fallbackServer.startAndWait()
        }
    }

    func stop() {
        server.stop()
        fallbackServer?.stop()
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
        var snapshot = await controlPlane.snapshot()
        snapshot.corpusVersion = library?.catalog.corpusVersion
        snapshot.originBinding = configuration.preferredPort == nil ? "ephemeral"
            : usesFallbackPort ? "cold_ephemeral_fallback" : "stable_preferred_port"
        return snapshot
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
                    : (source.data ?? Data())
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

    private static func loadRealResources(_ library: FeedDemoMediaLibrary) throws -> [String: Resource] {
        try Dictionary(uniqueKeysWithValues: library.catalog.resources.map { metadata in
            let clipID = metadata.path.split(separator: "/").first.map(String.init)
            return (
                "/\(library.catalog.corpusVersion)/\(metadata.path)",
                Resource(fileURL: try library.resourceURL(for: metadata.path), metadata: metadata, feedItemID: clipID)
            )
        })
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
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            return max(0, dataCount - suffix)...(dataCount - 1)
        }
        guard
              let lower = Int(bounds[0]), lower >= 0, lower < dataCount
        else {
            return nil
        }
        let requestedUpper = bounds[1].isEmpty ? dataCount - 1 : Int(bounds[1])
        guard let requestedUpper, requestedUpper >= lower else { return nil }
        return lower...min(requestedUpper, dataCount - 1)
    }
}
