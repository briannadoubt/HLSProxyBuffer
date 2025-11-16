import Foundation

public struct HTTPResponse: Sendable {
    public enum Status: Int, Sendable {
        case ok = 200
        case notFound = 404
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

    public func encoded() -> Data {
        var response = "HTTP/1.1 \(status.rawValue) \(reasonPhrase(for: status))\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "Content-Length: \(body.count)\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    public static func text(_ text: String, status: Status = .ok, contentType: String = "application/x-mpegURL") -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": contentType],
            body: Data(text.utf8)
        )
    }

    public static func json(_ object: [String: Any], status: Status = .ok) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: data ?? Data()
        )
    }

    private func reasonPhrase(for status: Status) -> String {
        switch status {
        case .ok: return "OK"
        case .notFound: return "Not Found"
        case .serviceUnavailable: return "Service Unavailable"
        case .internalServerError: return "Internal Server Error"
        }
    }
}
