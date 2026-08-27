import HLSCore

public struct ProxyPlayerLogger: Logger {
    private let base: DefaultLogger

    public init(configuration: LogConfiguration = .default) {
        self.base = DefaultLogger(
            subsystem: "com.hlsproxybuffer.proxy-player-kit",
            configuration: configuration
        )
    }

    public func isEnabled(level: LogLevel, category: LogCategory) -> Bool {
        base.isEnabled(level: level, category: category)
    }

    public func log(_ message: @autoclosure () -> String, category: LogCategory) {
        base.log(message(), category: category)
    }

    public func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        base.log(message(), level: level, category: category)
    }
}
