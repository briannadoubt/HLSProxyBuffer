import Foundation
import XCTest
@testable import HLSCore

final class LoggingTests: XCTestCase {
    func testConfigurationFiltersByLevelAndCategory() {
        let configuration = LogConfiguration(
            minimumLevel: .warning,
            enabledCategories: [.manifest, .segment],
            privacy: .private
        )

        XCTAssertFalse(configuration.isEnabled(level: .debug, category: .manifest))
        XCTAssertTrue(configuration.isEnabled(level: .warning, category: .manifest))
        XCTAssertTrue(configuration.isEnabled(level: .critical, category: .segment))
        XCTAssertFalse(configuration.isEnabled(level: .error, category: .player))
        XCTAssertFalse(LogConfiguration.disabled.isEnabled(level: .critical, category: .manifest))
    }

    func testDefaultLoggerDoesNotEvaluateFilteredMessages() {
        let logger = DefaultLogger(
            subsystem: "com.hlsproxybuffer.tests",
            configuration: LogConfiguration(
                minimumLevel: .warning,
                enabledCategories: [.manifest]
            )
        )
        var evaluations = 0

        logger.log(makeMessage(evaluations: &evaluations), category: .manifest)
        logger.log(makeMessage(evaluations: &evaluations), level: .debug, category: .manifest)
        logger.log(makeMessage(evaluations: &evaluations), level: .error, category: .scheduler)

        XCTAssertEqual(evaluations, 0)

        logger.log(makeMessage(evaluations: &evaluations), level: .error, category: .manifest)

        XCTAssertEqual(evaluations, 1)
    }

    func testCategoryOnlyCustomLoggerReceivesLevelAwareCalls() {
        let storage = RecordingLogStorage()
        let logger: any Logger = CategoryOnlyLogger(storage: storage)

        logger.log("origin retry", level: .warning, category: .manifest)

        XCTAssertEqual(storage.entries, [.init(message: "origin retry", category: .manifest)])
    }

    func testCustomLoggerCanFilterBeforeMessageConstruction() {
        let storage = RecordingLogStorage()
        let logger: any Logger = CategoryOnlyLogger(
            storage: storage,
            configuration: LogConfiguration(
                minimumLevel: .error,
                enabledCategories: [.segment]
            )
        )
        var evaluations = 0

        logger.log(makeMessage(evaluations: &evaluations), level: .debug, category: .segment)
        logger.log(makeMessage(evaluations: &evaluations), level: .error, category: .manifest)

        XCTAssertEqual(evaluations, 0)
        XCTAssertTrue(storage.entries.isEmpty)
    }

    private func makeMessage(evaluations: inout Int) -> String {
        evaluations += 1
        return "rendered"
    }
}

private struct CategoryOnlyLogger: Logger {
    let storage: RecordingLogStorage
    let configuration: LogConfiguration

    init(storage: RecordingLogStorage, configuration: LogConfiguration = .default) {
        self.storage = storage
        self.configuration = configuration
    }

    func isEnabled(level: LogLevel, category: LogCategory) -> Bool {
        configuration.isEnabled(level: level, category: category)
    }

    func log(_ message: @autoclosure () -> String, category: LogCategory) {
        storage.append(.init(message: message(), category: category))
    }
}

private final class RecordingLogStorage: @unchecked Sendable {
    struct Entry: Equatable {
        let message: String
        let category: LogCategory
    }

    private let lock = NSLock()
    private var storedEntries: [Entry] = []

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    func append(_ entry: Entry) {
        lock.lock()
        storedEntries.append(entry)
        lock.unlock()
    }
}
