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

    func testMemoryPressureDropsOnlyMemoryAndRecordsHighWaterAndReason() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HLSSegmentCache(
            capacityBytes: 16,
            diskDirectory: directory,
            diskCapacityBytes: 16
        )
        await cache.put(Data([0x01, 0x02, 0x03]), for: "segment-pressure")

        await cache.handleMemoryPressure()

        var metrics = await cache.metrics()
        XCTAssertEqual(metrics.totalBytes, 0)
        XCTAssertEqual(metrics.memoryEntryCount, 0)
        XCTAssertEqual(metrics.memoryHighWaterBytes, 3)
        XCTAssertEqual(metrics.diskBytes, 3)
        XCTAssertEqual(metrics.diskEntryCount, 1)
        XCTAssertEqual(metrics.diskHighWaterBytes, 3)
        XCTAssertEqual(metrics.evictionCounts[.memoryPressure], 1)
        XCTAssertEqual(metrics.metrics(for: .video).memoryEvictionCount, 1)

        let restored = await cache.get("segment-pressure")
        XCTAssertEqual(restored, Data([0x01, 0x02, 0x03]))
        metrics = await cache.metrics()
        XCTAssertEqual(metrics.diskHitCount, 1)
        XCTAssertEqual(metrics.totalBytes, 3)
    }

    func testOriginPolicyRemovalClearsBothTiersAndRecordsReason() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HLSSegmentCache(
            capacityBytes: 16,
            diskDirectory: directory,
            diskCapacityBytes: 16
        )
        await cache.put(Data([0x01]), for: "manifest-no-store")

        await cache.remove("manifest-no-store")

        let metrics = await cache.metrics()
        XCTAssertEqual(metrics.totalBytes, 0)
        XCTAssertEqual(metrics.diskBytes, 0)
        XCTAssertEqual(metrics.evictionCounts[.originPolicy], 2)
        let value = await cache.get("manifest-no-store")
        XCTAssertNil(value)
    }

    func testValidationMetadataPersistsAndExpiredBytesRemainAvailableForRevalidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let testClock = TestCacheClock()
        let validation = HLSSegmentCache.ValidationMetadata(
            eTag: "\"feed-v1\"",
            lastModified: "Wed, 26 Aug 2026 00:00:00 GMT",
            freshUntil: testClock.wallNow.addingTimeInterval(5)
        )
        let first = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 16,
            timeToLive: 60,
            clock: testClock.cacheClock
        )
        await first.put(Data([0xAA]), for: "manifest-feed", validation: validation)
        testClock.advance(by: 6)

        let reloaded = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 16,
            timeToLive: 60,
            clock: testClock.cacheClock
        )
        let stale = await reloaded.entry(for: "manifest-feed", allowingExpired: true)

        XCTAssertEqual(stale?.data, Data([0xAA]))
        XCTAssertEqual(stale?.validation, validation)
        XCTAssertEqual(stale?.isExpired, true)
        let metrics = await reloaded.metrics()
        XCTAssertEqual(metrics.missCount, 1)
        XCTAssertEqual(metrics.metrics(for: .video).expirationCount, 1)
        XCTAssertEqual(metrics.diskBytes, 1, "Revalidation keeps stale bytes until the origin answers")
    }

    func testValidationMetadataRejectsControlCharactersAndBoundsPersistedValues() {
        let metadata = HLSSegmentCache.ValidationMetadata(
            eTag: "safe\r\ninjected",
            lastModified: String(repeating: "a", count: 4_096)
        )

        XCTAssertNil(metadata.eTag)
        XCTAssertEqual(metadata.lastModified?.count, 512)
    }

    func testLongCanonicalKeyUsesBoundedPersistentIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "manifest-https://media.example/playlist.m3u8?token="
            + String(repeating: "abcdef0123456789", count: 128)
        let first = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 16
        )
        await first.put(Data([0x01]), for: key)
        let ownedFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let dataFile = try XCTUnwrap(ownedFiles.first { $0.hasPrefix("hlsproxy-v2-") })
        XCTAssertLessThan(dataFile.utf8.count, 128)

        let reloaded = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 16
        )
        let restored = await reloaded.get(key)
        XCTAssertEqual(restored, Data([0x01]))
    }

    func testEvictionReasonsDistinguishByteAndEntryLimits() async throws {
        let memory = HLSSegmentCache(capacityBytes: 1, maximumEntryCount: 2)
        await memory.put(Data([0x01, 0x02]), for: "too-large")
        await memory.put(Data(), for: "zero-1")
        await memory.put(Data(), for: "zero-2")
        await memory.put(Data(), for: "zero-3")
        let memoryMetrics = await memory.metrics()
        XCTAssertEqual(memoryMetrics.evictionCounts[.memoryByteLimit], 1)
        XCTAssertEqual(memoryMetrics.evictionCounts[.memoryEntryLimit], 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = HLSSegmentCache(
            capacityBytes: 0,
            diskDirectory: directory,
            diskCapacityBytes: 1,
            maximumEntryCount: 2
        )
        await disk.put(Data([0x01, 0x02]), for: "too-large")
        await disk.put(Data(), for: "zero-1")
        await disk.put(Data(), for: "zero-2")
        await disk.put(Data(), for: "zero-3")
        let diskMetrics = await disk.metrics()
        XCTAssertEqual(diskMetrics.evictionCounts[.diskByteLimit], 1)
        XCTAssertEqual(diskMetrics.evictionCounts[.diskEntryLimit], 1)
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

    var wallNow: Date {
        lock.withLock { state.wall }
    }

    func advance(by duration: TimeInterval) {
        lock.withLock {
            state.monotonic += duration
            state.wall.addTimeInterval(duration)
        }
    }
}
