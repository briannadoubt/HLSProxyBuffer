import Foundation

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case head = "HEAD"
        case post = "POST"
    }

    public let method: Method
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: Method, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

enum HTTPRequestParser {
    static func parse(data: Data) throws -> HTTPRequest {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidEncoding
        }

        let delimiter = "\r\n\r\n"
        guard let range = raw.range(of: delimiter) else {
            throw ParserError.missingHead
        }

        let head = String(raw[..<range.lowerBound])
        let body = String(raw[range.upperBound...])

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ParserError.missingHead
        }

        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else {
            throw ParserError.malformedRequestLine
        }

        guard let method = HTTPRequest.Method(rawValue: String(tokens[0])) else {
            throw ParserError.unsupportedMethod
        }

        let path = String(tokens[1])
        var headers: [String: String] = [:]

        for headerLine in lines.dropFirst() where !headerLine.isEmpty {
            let parts = headerLine.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        let bodyData = Data(body.utf8)
        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    enum ParserError: Error {
        case invalidEncoding
        case missingHead
        case malformedRequestLine
        case unsupportedMethod
    }
}
