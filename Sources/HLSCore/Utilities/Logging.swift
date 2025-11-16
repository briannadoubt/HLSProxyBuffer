import Foundation

public enum LogCategory: String, Sendable {
    case manifest
    case parser
    case rewriter
    case segment
    case cache
    case scheduler
    case proxy
    case player
    case debug
}

public protocol Logger: Sendable {
    func log(_ message: @autoclosure () -> String, category: LogCategory)
}

public extension Logger {
    func log(_ message: @autoclosure () -> String) {
        log(message(), category: .debug)
    }
}

public struct DefaultLogger: Logger {
    public init() {}

    public func log(_ message: @autoclosure () -> String, category: LogCategory) {
        #if DEBUG
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        print("[HLSCore][\(category.rawValue.uppercased())][\(timestamp)] \(message())")
        #endif
    }
}
