import Foundation
import os

/// Severity used to filter and route HLS proxy log messages.
public enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical
    case off

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate var osLogType: OSLogType {
        switch self {
        case .trace, .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .warning, .error:
            return .error
        case .critical:
            return .fault
        case .off:
            return .debug
        }
    }
}

public enum LogCategory: String, CaseIterable, Sendable {
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

/// Privacy applied to the fully rendered message passed to ``DefaultLogger``.
public enum LogPrivacy: Equatable, Sendable {
    /// Visible in Console without redaction. Use only for non-sensitive messages.
    case `public`
    /// Redacted using the platform's default private representation.
    case `private`
    /// Redacted with a stable hash, which is useful for correlating private values.
    case privateHash
}

/// Immutable filtering and privacy policy for structured logs.
public struct LogConfiguration: Equatable, Sendable {
    public static let `default` = LogConfiguration()
    public static let disabled = LogConfiguration(minimumLevel: .off)

    public let minimumLevel: LogLevel
    public let enabledCategories: Set<LogCategory>
    public let privacy: LogPrivacy

    public init(
        minimumLevel: LogLevel = .debug,
        enabledCategories: Set<LogCategory> = Set(LogCategory.allCases),
        privacy: LogPrivacy = .privateHash
    ) {
        self.minimumLevel = minimumLevel
        self.enabledCategories = enabledCategories
        self.privacy = privacy
    }

    public func isEnabled(level: LogLevel, category: LogCategory) -> Bool {
        minimumLevel != .off
            && level != .off
            && level >= minimumLevel
            && enabledCategories.contains(category)
    }
}

/// Injectable logging surface used throughout HLSProxyBuffer.
///
/// Existing loggers that implement the category-only requirement continue to
/// work. They can override ``isEnabled(level:category:)`` to make the default
/// level-aware entry point skip message construction before forwarding.
public protocol Logger: Sendable {
    func isEnabled(level: LogLevel, category: LogCategory) -> Bool
    func log(_ message: @autoclosure () -> String, category: LogCategory)
    func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory)
}

public extension Logger {
    func isEnabled(level: LogLevel, category: LogCategory) -> Bool {
        true
    }

    func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        guard isEnabled(level: level, category: category) else { return }
        log(message(), category: category)
    }

    func log(_ message: @autoclosure () -> String) {
        log(message(), level: .debug, category: .debug)
    }
}

/// An `os.Logger`-backed logger with eager filtering and explicit privacy.
public struct DefaultLogger: Logger {
    public let configuration: LogConfiguration

    private let loggers: [LogCategory: os.Logger]

    public init(
        subsystem: String = "com.hlsproxybuffer",
        configuration: LogConfiguration = .default
    ) {
        self.configuration = configuration
        self.loggers = Dictionary(
            uniqueKeysWithValues: LogCategory.allCases.map { category in
                (category, os.Logger(subsystem: subsystem, category: category.rawValue))
            }
        )
    }

    public func isEnabled(level: LogLevel, category: LogCategory) -> Bool {
        configuration.isEnabled(level: level, category: category)
    }

    public func log(_ message: @autoclosure () -> String, category: LogCategory) {
        log(message(), level: .debug, category: category)
    }

    public func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        guard configuration.isEnabled(level: level, category: category),
              let logger = loggers[category] else {
            return
        }

        let value = message()
        switch configuration.privacy {
        case .public:
            logger.log(level: level.osLogType, "\(value, privacy: .public)")
        case .private:
            logger.log(level: level.osLogType, "\(value, privacy: .private)")
        case .privateHash:
            logger.log(level: level.osLogType, "\(value, privacy: .private(mask: .hash))")
        }
    }
}
