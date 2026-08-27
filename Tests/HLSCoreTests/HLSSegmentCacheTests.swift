import XCTest
@testable import HLSCore

final class HLSSegmentCacheTests: XCTestCase {
    func testTTLExpiresUsingInjectedMonotonicClock() async throws {
        let testClock = TestCacheClock()
        let cache = HLSSegmentCache(
            capacityBytes: 16,
            timeToLive: 5,
            clock: testClock.cacheClock
        )
        await cache.put(Data([0x01]), for: "segment-1")

        testClock.advance(by: 4)
        let liveValue = await cache.get("segment-1")
        XCTAssertEqual(liveValue, Data([0x01]))
        testClock.advance(by: 1)
        let expiredValue = await cache.get("segment-1")
        XCTAssertNil(expiredValue)

        let metrics = await cache.metrics()
        let video = metrics.metrics(for: .video)
        XCTAssertEqual(video.hitCount, 1)
        XCTAssertEqual(video.missCount, 1)
        XCTAssertEqual(video.expirationCount, 1)
        XCTAssertEqual(metrics.totalBytes, 0)
    }

    func testDiskTTLAndLRUStateSurviveCacheReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let testClock = TestCacheClock()
        let key = "audio-main-segment-1"
        let first = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 16,
            timeToLive: 10,
            clock: testClock.cacheClock
        )
        await first.put(Data([0xAA]), for: key)

        testClock.advance(by: 6)
        let reloaded = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 16,
            timeToLive: 10,
            clock: testClock.cacheClock
        )
        let reloadedValue = await reloaded.get(key)
        XCTAssertEqual(reloadedValue, Data([0xAA]))

        testClock.advance(by: 5)
        let expiredValue = await reloaded.get(key)
        XCTAssertNil(expiredValue)
        let audio = await reloaded.metrics().metrics(for: .audio)
        XCTAssertEqual(audio.hitCount, 1)
        XCTAssertEqual(audio.missCount, 1)
        XCTAssertEqual(audio.expirationCount, 1)
        let ownedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("hlsproxy-") }
        XCTAssertTrue(ownedFiles.isEmpty)
    }

    func testNamespaceHitMissAndMemoryEvictionMetrics() async throws {
        let cache = HLSSegmentCache(capacityBytes: 2)
        await cache.put(Data([0x01]), for: "segment-1")
        let videoValue = await cache.get("segment-1")
        XCTAssertNotNil(videoValue)
        await cache.put(Data([0x02]), for: "audio-main-segment-1")
        let audioValue = await cache.get("audio-main-segment-1")
        XCTAssertNotNil(audioValue)
        await cache.put(Data([0x03]), for: "subtitles-en-segment-1")
        let evictedVideoValue = await cache.get("segment-1")
        let subtitleValue = await cache.get("subtitles-en-segment-1")
        XCTAssertNil(evictedVideoValue)
        XCTAssertNotNil(subtitleValue)

        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.metrics(for: .video).hitCount, 1)
        XCTAssertEqual(metrics.metrics(for: .video).missCount, 1)
        XCTAssertEqual(metrics.metrics(for: .video).memoryEvictionCount, 1)
        XCTAssertEqual(metrics.metrics(for: .audio).hitCount, 1)
        XCTAssertEqual(metrics.metrics(for: .subtitle).hitCount, 1)
        XCTAssertEqual(metrics.namespaceMetrics.count, 3)
    }

    func testEntryQuotaBoundsZeroByteMetadata() async throws {
        let cache = HLSSegmentCache(capacityBytes: 1_024, maximumEntryCount: 2)
        await cache.put(Data(), for: "segment-1")
        await cache.put(Data(), for: "audio-main-segment-1")
        await cache.put(Data(), for: "subtitles-en-segment-1")

        let videoValue = await cache.get("segment-1")
        let audioValue = await cache.get("audio-main-segment-1")
        let subtitleValue = await cache.get("subtitles-en-segment-1")
        XCTAssertNil(videoValue)
        XCTAssertNotNil(audioValue)
        XCTAssertNotNil(subtitleValue)
        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.totalBytes, 0)
        XCTAssertEqual(metrics.metrics(for: .video).memoryEvictionCount, 1)
    }

    func testDiskQuotaReloadAndNamespaceEvictions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 2,
            maximumEntryCount: 2
        )
        await cache.put(Data([0x01]), for: "segment-1")
        await cache.put(Data([0x02]), for: "audio-main-segment-1")
        await cache.put(Data([0x03]), for: "subtitles-en-segment-1")

        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.diskBytes, 2)
        XCTAssertEqual(metrics.metrics(for: .video).diskEvictionCount, 1)

        let reloaded = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 2,
            maximumEntryCount: 2
        )
        let videoValue = await reloaded.get("segment-1")
        let audioValue = await reloaded.get("audio-main-segment-1")
        let subtitleValue = await reloaded.get("subtitles-en-segment-1")
        XCTAssertNil(videoValue)
        XCTAssertEqual(audioValue, Data([0x02]))
        XCTAssertEqual(subtitleValue, Data([0x03]))
    }

    func testConcurrentAccessPreservesBudgetsAndFixedMetricCardinality() async throws {
        let cache = HLSSegmentCache(capacityBytes: 32, maximumEntryCount: 32)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                group.addTask {
                    let prefix = switch index % 3 {
                    case 1: "audio-main-"
                    case 2: "subtitles-en-"
                    default: ""
                    }
                    let key = "\(prefix)segment-\(index)"
                    await cache.put(Data([UInt8(index % 255)]), for: key)
                    _ = await cache.get(key)
                }
            }
        }

        let metrics = await cache.metrics()
        XCTAssertLessThanOrEqual(metrics.totalBytes, 32)
        XCTAssertEqual(metrics.namespaceMetrics.count, 3)
        XCTAssertEqual(
            metrics.namespaceMetrics.values.reduce(0) { $0 + $1.hitCount + $1.missCount },
            128
        )
    }

    func testLRUEviction() async throws {
        let cache = HLSSegmentCache(capacityBytes: 2)
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

        let cache = HLSSegmentCache(capacityBytes: 1, diskDirectory: directory)
        await cache.put(Data([0xAA]), for: "one")
        await cache.put(Data([0xBB]), for: "two") // evicts "one" from memory but keeps on disk

        let fromMemory = await cache.get("two")
        XCTAssertEqual(fromMemory, Data([0xBB]))

        let resurrected = await cache.get("one")
        XCTAssertEqual(resurrected, Data([0xAA]), "Disk cache should restore evicted entry.")
        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.hitCount, 2)
        XCTAssertEqual(metrics.memoryHitCount, 1)
        XCTAssertEqual(metrics.diskHitCount, 1)
    }

    func testMetricsReportDiskBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = HLSSegmentCache(capacityBytes: 1, diskDirectory: directory)
        await cache.put(Data([0x11, 0x22]), for: "metric")
        let metrics = await cache.metrics()
        XCTAssertGreaterThanOrEqual(metrics.diskBytes, 2)
    }

    func testClearPreservesFilesNotOwnedByCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelated = directory.appendingPathComponent("keep-me.txt")
        try Data("owned by caller".utf8).write(to: unrelated)
        let cache = HLSSegmentCache(capacityBytes: 16, diskDirectory: directory)
        await cache.put(Data([0xAA]), for: "cache-key")

        await cache.clear()

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        let cleared = await cache.get("cache-key")
        XCTAssertNil(cleared)
    }
}

private final class TestCacheClock: @unchecked Sendable {
    private struct State {
        var monotonic: TimeInterval = 0
        var wall = Date()
    }

    private let lock = NSLock()
    private var state = State()

    var cacheClock: HLSSegmentCache.Clock {
        HLSSegmentCache.Clock(
            monotonicNow: { [self] in lock.withLock { state.monotonic } },
            wallNow: { [self] in lock.withLock { state.wall } }
        )
    }

    func advance(by duration: TimeInterval) {
        lock.withLock {
            state.monotonic += duration
            state.wall.addTimeInterval(duration)
        }
    }
}
