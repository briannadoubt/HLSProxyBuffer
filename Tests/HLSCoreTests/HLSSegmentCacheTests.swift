import XCTest
@testable import HLSCore

final class HLSSegmentCacheTests: XCTestCase {
    func testLRUEviction() async throws {
        let cache = HLSSegmentCache(capacity: 2)
        await cache.put(Data([0x0]), for: "a")
        await cache.put(Data([0x1]), for: "b")

        let firstHit = await cache.get("a")
        XCTAssertNotNil(firstHit)

        await cache.put(Data([0x2]), for: "c")

        let evicted = await cache.get("b")
        XCTAssertNil(evicted, "Least recently used entry should evict first.")
        let stillA = await cache.get("a")
        let stillC = await cache.get("c")
        XCTAssertNotNil(stillA)
        XCTAssertNotNil(stillC)
    }

    func testDiskCachePersistsEvictedEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let cache = HLSSegmentCache(capacity: 1, diskDirectory: directory)
        await cache.put(Data([0xAA]), for: "one")
        await cache.put(Data([0xBB]), for: "two") // evicts "one" from memory but keeps on disk

        let fromMemory = await cache.get("two")
        XCTAssertEqual(fromMemory, Data([0xBB]))

        let resurrected = await cache.get("one")
        XCTAssertEqual(resurrected, Data([0xAA]), "Disk cache should restore evicted entry.")
    }

    func testMetricsReportDiskBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = HLSSegmentCache(capacity: 1, diskDirectory: directory)
        await cache.put(Data([0x11, 0x22]), for: "metric")
        let metrics = await cache.metrics()
        XCTAssertGreaterThanOrEqual(metrics.diskBytes, 2)
    }
}
