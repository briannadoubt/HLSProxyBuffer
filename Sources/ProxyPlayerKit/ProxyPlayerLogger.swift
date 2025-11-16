import Foundation
import HLSCore

public struct ProxyPlayerLogger: Logger {
    public init() {}

    public func log(_ message: @autoclosure () -> String, category: LogCategory) {
        #if DEBUG
        print("[ProxyPlayerKit][\(category.rawValue.uppercased())] \(message())")
        #endif
    }
}
