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

    public init(status: Status, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func headerData(connection: String = "keep-alive") -> Data {
        var response = "HTTP/1.1 \(status.rawValue) \(reasonPhrase(for: status))\r\n"
        var renderedHeaders = headers
        renderedHeaders["Content-Length"] = "\(body.count)"
        renderedHeaders["Connection"] = renderedHeaders["Connection"] ?? connection
        for (key, value) in renderedHeaders.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        return Data(response.utf8)
    }

    public func encoded(includeBody: Bool = true) -> Data {
        var data = headerData(connection: "close")
        if includeBody {
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
