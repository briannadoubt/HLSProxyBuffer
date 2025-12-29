import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case none = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .none: return "NONE"
        }
    }
}

public enum LogCategory: String, Sendable, CaseIterable {
    case manifest
    case parser
    case rewriter
    case segment
    case cache
    case scheduler
    case proxy
    case player
    case debug
    case network
    case metrics
    case abr
}

public enum LogFormat: Sendable {
    case text
    case json
}

public protocol Logger: Sendable {
    func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory)
}

public extension Logger {
    func log(_ message: @autoclosure () -> String, category: LogCategory) {
        log(message(), level: .debug, category: category)
    }

    func log(_ message: @autoclosure () -> String) {
        log(message(), level: .debug, category: .debug)
    }

    func trace(_ message: @autoclosure () -> String, category: LogCategory = .debug) {
        log(message(), level: .trace, category: category)
    }

    func debug(_ message: @autoclosure () -> String, category: LogCategory = .debug) {
        log(message(), level: .debug, category: category)
    }

    func info(_ message: @autoclosure () -> String, category: LogCategory = .debug) {
        log(message(), level: .info, category: category)
    }

    func warning(_ message: @autoclosure () -> String, category: LogCategory = .debug) {
        log(message(), level: .warning, category: category)
    }

    func error(_ message: @autoclosure () -> String, category: LogCategory = .debug) {
        log(message(), level: .error, category: category)
    }
}

public struct DefaultLogger: Logger {
    public init() {}

    public func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        #if DEBUG
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        print("[HLSCore][\(level.label)][\(category.rawValue.uppercased())][\(timestamp)] \(message())")
        #endif
    }
}

/// Configurable logger with log level filtering and format options
public final class ConfigurableLogger: Logger, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var minimumLevel: LogLevel
        public var format: LogFormat
        public var enabledCategories: Set<LogCategory>?
        public var includeSourceLocation: Bool

        public init(
            minimumLevel: LogLevel = .info,
            format: LogFormat = .text,
            enabledCategories: Set<LogCategory>? = nil,
            includeSourceLocation: Bool = false
        ) {
            self.minimumLevel = minimumLevel
            self.format = format
            self.enabledCategories = enabledCategories
            self.includeSourceLocation = includeSourceLocation
        }
    }

    private let configuration: Configuration
    private let dateFormatter: ISO8601DateFormatter
    private let output: (@Sendable (String) -> Void)?

    public init(configuration: Configuration = .init(), output: (@Sendable (String) -> Void)? = nil) {
        self.configuration = configuration
        self.output = output
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone, .withFractionalSeconds]
    }

    public func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        guard level >= configuration.minimumLevel else { return }
        if let enabledCategories = configuration.enabledCategories, !enabledCategories.contains(category) {
            return
        }

        let timestamp = dateFormatter.string(from: Date())
        let messageValue = message()

        let formatted: String
        switch configuration.format {
        case .text:
            formatted = "[HLSProxy][\(level.label)][\(category.rawValue.uppercased())][\(timestamp)] \(messageValue)"
        case .json:
            let escaped = messageValue
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            formatted = """
            {"timestamp":"\(timestamp)","level":"\(level.label)","category":"\(category.rawValue)","message":"\(escaped)"}
            """
        }

        if let output {
            output(formatted)
        } else {
            print(formatted)
        }
    }
}

/// Log entry for structured logging and metrics collection
public struct LogEntry: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }

    public func toJSON() -> String {
        var fields: [String] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone, .withFractionalSeconds]

        fields.append("\"timestamp\":\"\(formatter.string(from: timestamp))\"")
        fields.append("\"level\":\"\(level.label)\"")
        fields.append("\"category\":\"\(category.rawValue)\"")

        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        fields.append("\"message\":\"\(escapedMessage)\"")

        if !metadata.isEmpty {
            let metadataFields = metadata.map { key, value in
                let escapedValue = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(key)\":\"\(escapedValue)\""
            }
            fields.append("\"metadata\":{\(metadataFields.joined(separator: ","))}")
        }

        return "{\(fields.joined(separator: ","))}"
    }
}

/// Logger that collects entries for batch processing or metrics
public actor BufferedLogger: Logger {
    public struct Configuration: Sendable {
        public var minimumLevel: LogLevel
        public var maxBufferSize: Int
        public var flushHandler: (@Sendable ([LogEntry]) async -> Void)?

        public init(
            minimumLevel: LogLevel = .info,
            maxBufferSize: Int = 100,
            flushHandler: (@Sendable ([LogEntry]) async -> Void)? = nil
        ) {
            self.minimumLevel = minimumLevel
            self.maxBufferSize = maxBufferSize
            self.flushHandler = flushHandler
        }
    }

    private var buffer: [LogEntry] = []
    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    nonisolated public func log(_ message: @autoclosure () -> String, level: LogLevel, category: LogCategory) {
        let messageValue = message()
        Task {
            await appendEntry(LogEntry(level: level, category: category, message: messageValue))
        }
    }

    public func appendEntry(_ entry: LogEntry) async {
        guard entry.level >= configuration.minimumLevel else { return }
        buffer.append(entry)
        if buffer.count >= configuration.maxBufferSize {
            await flush()
        }
    }

    public func flush() async {
        guard !buffer.isEmpty else { return }
        let entries = buffer
        buffer.removeAll()
        await configuration.flushHandler?(entries)
    }

    public func entries() -> [LogEntry] {
        buffer
    }
}
