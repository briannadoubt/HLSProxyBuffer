import Foundation
import HLSCore

public struct ProxyPlayerLogger: Logger {
    public init() {}

    public func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        #if DEBUG
        print("[ProxyPlayerKit][\(level.label)][\(category.rawValue.uppercased())] \(message())")
        #endif
    }
}
