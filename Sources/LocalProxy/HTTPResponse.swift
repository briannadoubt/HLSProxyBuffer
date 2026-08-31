import Foundation

public struct HTTPResponse: Sendable {
    public enum Status: Int, Sendable {
        case ok = 200
        case partialContent = 206
        case notModified = 304
        case badRequest = 400
        case notFound = 404
        case methodNotAllowed = 405
        case rangeNotSatisfiable = 416
        case payloadTooLarge = 413
        case serviceUnavailable = 503
        case internalServerError = 500
    }

    public let status: Status
    public var headers: [String: String]
    public var body: Data
    /// Size of the selected representation when its body is intentionally absent
    /// (HEAD or 304). Normal responses always derive framing from the actual body.
    public let representationLength: Int?
    private let bodyLifetime: BodyLifetime?

    private final class BodyLifetime: Sendable {
        let release: @Sendable () -> Void
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }

    /// `onBodyRelease` runs once when the last response copy is released. The
    /// server retains that copy through transport completion, including errors.
    /// Use it to release body admission/storage resources, not to infer receipt
    /// by the remote client. Callers retaining body bytes separately own those bytes.
    public init(
        status: Status,
        headers: [String: String] = [:],
        body: Data = Data(),
        representationLength: Int? = nil,
        onBodyRelease: (@Sendable () -> Void)? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.representationLength = representationLength.map { max(0, $0) }
        self.bodyLifetime = onBodyRelease.map(BodyLifetime.init)
    }

    public func headerData(connection: String = "keep-alive", includeBody: Bool = true) -> Data {
        var response = "HTTP/1.1 \(status.rawValue) \(reasonPhrase(for: status))\r\n"
        var renderedHeaders = headers.filter { $0.key.lowercased() != "content-length" }
        if status == .notModified {
            // RFC 9110 §8.6: omit rather than incorrectly advertise an empty representation.
            if let representationLength {
                renderedHeaders["Content-Length"] = "\(representationLength)"
            }
        } else {
            let count = includeBody ? body.count : (representationLength ?? body.count)
            renderedHeaders["Content-Length"] = "\(count)"
        }
        renderedHeaders["Connection"] = renderedHeaders["Connection"] ?? connection
        for (key, value) in renderedHeaders.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8)
    }

    public func encoded(includeBody: Bool = true) -> Data {
        var data = headerData(connection: "close", includeBody: includeBody)
        if includeBody && status != .notModified {
            data.append(body)
        }
        return data
    }

    public static func text(
        _ text: String,
        status: Status = .ok,
        contentType: String = "application/vnd.apple.mpegurl"
    ) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": contentType, "Cache-Control": "no-cache"],
            body: Data(text.utf8)
        )
    }

    public static func json(_ object: [String: Any], status: Status = .ok) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: data ?? Data()
        )
    }

    private func reasonPhrase(for status: Status) -> String {
        switch status {
        case .ok: return "OK"
        case .partialContent: return "Partial Content"
        case .notModified: return "Not Modified"
        case .badRequest: return "Bad Request"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .rangeNotSatisfiable: return "Range Not Satisfiable"
        case .payloadTooLarge: return "Content Too Large"
        case .serviceUnavailable: return "Service Unavailable"
        case .internalServerError: return "Internal Server Error"
        }
    }
}
