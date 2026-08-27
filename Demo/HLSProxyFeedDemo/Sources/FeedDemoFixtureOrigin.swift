import Foundation
import LocalProxy

final class FeedDemoFixtureOrigin: Sendable {
    private enum StartError: Error {
        case timedOut
    }

    private struct Resource: Sendable {
        let data: Data
        let contentType: String
        let etag: String
    }

    private let server: ProxyServer

    init() throws {
        let resources = try Self.loadResources()
        let router = ProxyRouter()
        router.register(path: "/*") { request in
            Self.response(for: request, resources: resources)
        }
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

    private static func response(
        for request: HTTPRequest,
        resources: [String: Resource]
    ) -> HTTPResponse {
        guard request.method == .get || request.method == .head,
              let resource = resources[request.path]
        else {
            return HTTPResponse(status: request.method == .post ? .methodNotAllowed : .notFound)
        }
        if request.headers["if-none-match"] == resource.etag {
            return HTTPResponse(
                status: .notModified,
                headers: validationHeaders(for: resource)
            )
        }
        if let rangeHeader = request.headers["range"] {
            guard let range = parseRange(rangeHeader, dataCount: resource.data.count) else {
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
        [
            "Accept-Ranges": "bytes",
            "Cache-Control": "public, max-age=60",
            "ETag": resource.etag,
        ]
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
