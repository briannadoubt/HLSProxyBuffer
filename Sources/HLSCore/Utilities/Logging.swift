import Foundation
import os

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
        let logger = os.Logger(subsystem: "com.hlsproxybuffer", category: category.rawValue)
        let value = message()
        logger.debug("\(value, privacy: .private(mask: .hash))")
    }
}
