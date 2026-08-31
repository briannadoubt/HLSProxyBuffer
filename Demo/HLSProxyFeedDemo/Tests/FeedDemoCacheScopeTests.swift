import Foundation
import XCTest
@testable import HLSProxyFeedDemo

final class FeedDemoCacheScopeTests: XCTestCase {
    func testQualificationResetsOnlyItsReservedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = root.appendingPathComponent("HLSProxyBuffer/FeedPreparation", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        let preserved = ordinary.appendingPathComponent("persistent-segment")
        try Data([1, 2, 3]).write(to: preserved)

        let first = try XCTUnwrap(FeedDemoCacheScope.freshQualification.prepareDirectory(in: root))
        XCTAssertNotEqual(first, ordinary)
        let obsolete = first.appendingPathComponent("previous-qualification-segment")
        try Data([4, 5, 6]).write(to: obsolete)
        let second = try XCTUnwrap(FeedDemoCacheScope.freshQualification.prepareDirectory(in: root))
        XCTAssertEqual(first, second, "Repeated runs must not accumulate cache namespaces")
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
        XCTAssertEqual(try Data(contentsOf: preserved), Data([1, 2, 3]))
    }

    func testPersistentScopeDoesNotCreateOrDeleteFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(try FeedDemoCacheScope.persistent.prepareDirectory(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
