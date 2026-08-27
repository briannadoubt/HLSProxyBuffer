import Foundation

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case head = "HEAD"
        case post = "POST"
    }

    public let method: Method
    public let path: String
    public let queryItems: [String: String]
    public let version: String
    public let headers: [String: String]
    public let body: Data

    public init(
        method: Method,
        path: String,
        queryItems: [String: String] = [:],
        version: String = "HTTP/1.1",
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.version = version
        self.headers = headers
        self.body = body
    }

    public var shouldKeepAlive: Bool {
        let connection = headers["connection"]?.lowercased()
        if version == "HTTP/1.0" {
            return connection == "keep-alive"
        }
        return connection != "close"
    }
}

enum HTTPRequestParser {
    static let maximumRequestBytes = 64 * 1024
    private static let headerTerminator = Data([13, 10, 13, 10])

    struct ParsedRequest {
        let request: HTTPRequest
        let consumedBytes: Int
    }

    static func parse(data: Data) throws -> HTTPRequest {
        guard let parsed = try parseAvailable(data: data) else {
            throw ParserError.incompleteRequest
        }
        return parsed.request
    }

    static func parseAvailable(
        data: Data,
        maximumRequestBytes: Int = HTTPRequestParser.maximumRequestBytes
    ) throws -> ParsedRequest? {
        guard data.count <= maximumRequestBytes else { throw ParserError.requestTooLarge }
        guard let delimiterRange = data.range(of: headerTerminator) else { return nil }
        let headData = data[..<delimiterRange.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            throw ParserError.invalidEncoding
        }

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ParserError.missingHead }
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 3 else { throw ParserError.malformedRequestLine }
        guard let method = HTTPRequest.Method(rawValue: String(tokens[0])) else {
            throw ParserError.unsupportedMethod
        }

        let target = String(tokens[1])
        let version = String(tokens[2])
        guard target.hasPrefix("/") else { throw ParserError.malformedRequestTarget }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw ParserError.unsupportedVersion
        }

        var headers: [String: String] = [:]
        for headerLine in lines.dropFirst() where !headerLine.isEmpty {
            let parts = headerLine.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw ParserError.malformedHeader }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ParserError.malformedHeader }
            if key == "content-length", headers[key] != nil {
                throw ParserError.duplicateContentLength
            }
            if key == "transfer-encoding" {
                throw ParserError.unsupportedTransferEncoding
            }
            headers[key] = value
        }

        let contentLength = try parsedContentLength(headers["content-length"])
        let bodyStart = delimiterRange.upperBound
        let consumedBytes = bodyStart + contentLength
        guard data.count >= consumedBytes else { return nil }
        let body = data.subdata(in: bodyStart..<consumedBytes)

        let components = URLComponents(string: "http://127.0.0.1\(target)")
        guard let path = components?.percentEncodedPath, path.hasPrefix("/") else {
            throw ParserError.malformedRequestTarget
        }
        let queryItems = Dictionary(
            (components?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { _, newest in newest }
        )

        return ParsedRequest(
            request: HTTPRequest(
                method: method,
                path: path,
                queryItems: queryItems,
                version: version,
                headers: headers,
                body: body
            ),
            consumedBytes: consumedBytes
        )
    }

    private static func parsedContentLength(_ value: String?) throws -> Int {
        guard let value else { return 0 }
        guard let length = Int(value), length >= 0 else { throw ParserError.invalidContentLength }
        return length
    }

    enum ParserError: Error {
        case invalidEncoding
        case missingHead
        case incompleteRequest
        case requestTooLarge
        case malformedRequestLine
        case malformedRequestTarget
        case malformedHeader
        case invalidContentLength
        case duplicateContentLength
        case unsupportedTransferEncoding
        case unsupportedMethod
        case unsupportedVersion
    }
}
