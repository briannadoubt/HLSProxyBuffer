#if canImport(Network)
import Foundation
import Network
@testable import LocalProxy

final class FeedFixtureOrigin: @unchecked Sendable {
    struct Profile: Equatable, Sendable {
        struct Fault: Equatable, Sendable {
            enum Action: Equatable, Sendable {
                case serviceUnavailable
                case disconnect(afterBodyBytes: Int)
            }

            let path: String
            let attempts: ClosedRange<Int>
            let action: Action

            init(path: String, attempts: ClosedRange<Int>, action: Action) {
                self.path = path
                self.attempts = attempts
                self.action = action
            }
        }

        var responseDelay: Duration
        var bytesPerSecond: Int?
        var faults: [Fault]

        init(
            responseDelay: Duration = .zero,
            bytesPerSecond: Int? = nil,
            faults: [Fault] = []
        ) {
            self.responseDelay = max(.zero, responseDelay)
            self.bytesPerSecond = bytesPerSecond.map { max(1, $0) }
            self.faults = faults
        }
    }

    struct TimelineEvent: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case requestStarted
            case responseStarted
            case responseBytes
            case requestFinished
            case requestCancelled
            case serverDisconnected
        }

        let tick: Int
        let requestID: UInt64
        let kind: Kind
        let path: String
        let attempt: Int
        let activeRequests: Int
        let bytes: Int
        let statusCode: Int?
        let requestedRange: String?
    }

    private struct Resource: Sendable {
        let data: Data
        let contentType: String
        let etag: String
    }

    private final class RequestState: @unchecked Sendable {
        let id: UInt64
        let path: String
        let attempt: Int
        let requestedRange: String?
        var finished = false

        init(id: UInt64, path: String, attempt: Int, requestedRange: String?) {
            self.id = id
            self.path = path
            self.attempt = attempt
            self.requestedRange = requestedRange
        }
    }

    private struct PreparedResponse: Sendable {
        let response: HTTPResponse
        let disconnectAfterBodyBytes: Int?
    }

    private static let lastModified = "Wed, 26 Aug 2026 00:00:00 GMT"

    private let queue = DispatchQueue(label: "FeedFixtureOrigin")
    private let profile: Profile
    private let resources: [String: Resource]
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [ObjectIdentifier: RequestState] = [:]
    private var requestAttempts: [String: Int] = [:]
    private var timeline: [TimelineEvent] = []
    private var nextRequestID: UInt64 = 1
    private var logicalTick = 0
    private var activeRequestCount = 0

    init(profile: Profile = .init()) throws {
        self.profile = profile
        self.resources = try Self.loadResources()
    }

    var baseURL: URL {
        guard let port = listener?.port?.rawValue,
              let url = URL(string: "http://127.0.0.1:\(port)")
        else {
            preconditionFailure("FeedFixtureOrigin must be started before requesting its URL")
        }
        return url
    }

    func url(for path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(normalizedPath)
    }

    func fixturePlaylistURL(named fixtureName: String) -> URL {
        url(for: "/\(fixtureName)/playlist.m3u8")
    }

    func start() async throws {
        let newListener = try NWListener(using: .tcp, on: 0)
        listener = newListener
        try await withCheckedThrowingContinuation { continuation in
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    newListener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    newListener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    func timelineSnapshot() -> [TimelineEvent] {
        queue.sync { timeline }
    }

    func resetTimeline() {
        queue.sync {
            timeline.removeAll(keepingCapacity: true)
            requestAttempts.removeAll(keepingCapacity: true)
            logicalTick = 0
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cancelPendingRequest(for: key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, key: key, accumulated: Data())
    }

    private func receiveRequest(
        on connection: NWConnection,
        key: ObjectIdentifier,
        accumulated: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.cancelPendingRequest(for: key)
                return
            }
            var received = accumulated
            if let data {
                received.append(data)
            }
            do {
                guard let parsed = try HTTPRequestParser.parseAvailable(data: received) else {
                    self.receiveRequest(on: connection, key: key, accumulated: received)
                    return
                }
                self.handle(parsed.request, on: connection, key: key)
            } catch {
                let response = HTTPResponse(status: .badRequest)
                connection.send(content: response.encoded(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection, key: ObjectIdentifier) {
        let attempt = requestAttempts[request.path, default: 0] + 1
        requestAttempts[request.path] = attempt
        let state = RequestState(
            id: nextRequestID,
            path: request.path,
            attempt: attempt,
            requestedRange: request.headers["range"]
        )
        nextRequestID &+= 1
        requests[key] = state
        activeRequestCount += 1
        record(.requestStarted, state: state)

        let prepared = prepareResponse(for: request, attempt: attempt)
        let delay = profile.responseDelay.timeInterval
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.send(prepared, on: connection, key: key, state: state)
        }
    }

    private func prepareResponse(for request: HTTPRequest, attempt: Int) -> PreparedResponse {
        if let fault = profile.faults.first(where: {
            $0.path == request.path && $0.attempts.contains(attempt)
        }) {
            switch fault.action {
            case .serviceUnavailable:
                return PreparedResponse(
                    response: HTTPResponse(
                        status: .serviceUnavailable,
                        headers: ["Retry-After": "0", "Cache-Control": "no-store"]
                    ),
                    disconnectAfterBodyBytes: nil
                )
            case .disconnect(let byteCount):
                let regular = regularResponse(for: request)
                return PreparedResponse(
                    response: regular,
                    disconnectAfterBodyBytes: max(0, byteCount)
                )
            }
        }
        return PreparedResponse(response: regularResponse(for: request), disconnectAfterBodyBytes: nil)
    }

    private func regularResponse(for request: HTTPRequest) -> HTTPResponse {
        guard let resource = resources[request.path] else {
            return HTTPResponse(status: .notFound, headers: ["Cache-Control": "no-store"])
        }

        let validatorMatches = request.headers["if-none-match"] == resource.etag
            || request.headers["if-modified-since"] == Self.lastModified
        if validatorMatches {
            return HTTPResponse(
                status: .notModified,
                headers: validationHeaders(for: resource)
            )
        }

        if let rangeValue = request.headers["range"] {
            guard let range = Self.parseRange(rangeValue, dataCount: resource.data.count) else {
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
                body: resource.data.subdata(in: range.lowerBound..<(range.upperBound + 1))
            )
        }

        var headers = validationHeaders(for: resource)
        headers["Content-Type"] = resource.contentType
        let body = request.method == .head ? Data() : resource.data
        return HTTPResponse(status: .ok, headers: headers, body: body)
    }

    private func validationHeaders(for resource: Resource) -> [String: String] {
        [
            "Accept-Ranges": "bytes",
            "Cache-Control": "public, max-age=60",
            "ETag": resource.etag,
            "Last-Modified": Self.lastModified,
        ]
    }

    private func send(
        _ prepared: PreparedResponse,
        on connection: NWConnection,
        key: ObjectIdentifier,
        state: RequestState
    ) {
        guard !state.finished else { return }
        record(
            .responseStarted,
            state: state,
            statusCode: prepared.response.status.rawValue
        )
        let header = prepared.response.headerData(connection: "close")
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.cancelPendingRequest(for: key)
                return
            }
            self.sendBody(
                prepared.response.body,
                offset: 0,
                disconnectAfterBodyBytes: prepared.disconnectAfterBodyBytes,
                on: connection,
                key: key,
                state: state
            )
        })
    }

    private func sendBody(
        _ body: Data,
        offset: Int,
        disconnectAfterBodyBytes: Int?,
        on connection: NWConnection,
        key: ObjectIdentifier,
        state: RequestState
    ) {
        guard !state.finished else { return }
        if let disconnectAfterBodyBytes, offset >= disconnectAfterBodyBytes {
            record(.serverDisconnected, state: state, bytes: offset)
            finish(state: state, key: key, connection: connection, recordFinished: false)
            return
        }
        guard offset < body.count else {
            finish(state: state, key: key, connection: connection, recordFinished: true)
            return
        }

        let bytesPerSecond = profile.bytesPerSecond
        let chunkSize = bytesPerSecond.map { max(1, $0 / 20) } ?? body.count
        let faultBoundary = disconnectAfterBodyBytes ?? body.count
        let end = min(body.count, offset + chunkSize, faultBoundary)
        let chunk = body.subdata(in: offset..<end)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.cancelPendingRequest(for: key)
                return
            }
            self.record(.responseBytes, state: state, bytes: chunk.count)
            let interval = bytesPerSecond == nil ? 0 : 0.05
            self.queue.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.sendBody(
                    body,
                    offset: end,
                    disconnectAfterBodyBytes: disconnectAfterBodyBytes,
                    on: connection,
                    key: key,
                    state: state
                )
            }
        })
    }

    private func finish(
        state: RequestState,
        key: ObjectIdentifier,
        connection: NWConnection,
        recordFinished: Bool
    ) {
        guard !state.finished else { return }
        state.finished = true
        activeRequestCount = max(0, activeRequestCount - 1)
        if recordFinished {
            record(.requestFinished, state: state)
        }
        requests.removeValue(forKey: key)
        connections.removeValue(forKey: key)
        connection.cancel()
    }

    private func cancelPendingRequest(for key: ObjectIdentifier) {
        guard let state = requests[key], !state.finished else {
            connections.removeValue(forKey: key)
            return
        }
        state.finished = true
        activeRequestCount = max(0, activeRequestCount - 1)
        record(.requestCancelled, state: state)
        requests.removeValue(forKey: key)
        connections.removeValue(forKey: key)
    }

    private func record(
        _ kind: TimelineEvent.Kind,
        state: RequestState,
        bytes: Int = 0,
        statusCode: Int? = nil
    ) {
        logicalTick += 1
        timeline.append(TimelineEvent(
            tick: logicalTick,
            requestID: state.id,
            kind: kind,
            path: state.path,
            attempt: state.attempt,
            activeRequests: activeRequestCount,
            bytes: bytes,
            statusCode: statusCode,
            requestedRange: state.requestedRange
        ))
    }

    private static func loadResources() throws -> [String: Resource] {
        guard let resourceRoot = Bundle.module.resourceURL?.appendingPathComponent(
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
                etag: etag(for: data)
            )
        }
        return result
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "m3u8": "application/vnd.apple.mpegurl"
        case "mp4", "m4s": "video/mp4"
        case "json": "application/json"
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

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
