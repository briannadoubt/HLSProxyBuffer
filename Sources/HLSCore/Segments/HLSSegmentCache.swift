import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

public actor HLSSegmentCache: Caching {
    /// A fixed-cardinality classification for cache telemetry.
    public enum Namespace: String, CaseIterable, Hashable, Sendable {
        case video
        case audio
        case subtitle

        fileprivate static func classify(_ key: String) -> Self {
            let normalized = key.lowercased()
            if normalized.hasPrefix("audio-") { return .audio }
            if normalized.hasPrefix("subtitle-")
                || normalized.hasPrefix("subtitles-")
                || normalized.hasPrefix("closed-caption-")
                || normalized.hasPrefix("closed-captions-") {
                return .subtitle
            }
            return .video
        }
    }

    /// Injectable time sources. Active-entry expiration uses the monotonic value;
    /// the wall value is used only to restore TTL age from compatible disk files.
    public struct Clock: Sendable {
        public static let continuous: Clock = {
            let clock = ContinuousClock()
            let origin = clock.now
            return Clock(
                monotonicNow: {
                    let components = origin.duration(to: clock.now).components
                    return Double(components.seconds)
                        + Double(components.attoseconds) / 1_000_000_000_000_000_000
                },
                wallNow: { Date() }
            )
        }()

        private let monotonicNowProvider: @Sendable () -> TimeInterval
        private let wallNowProvider: @Sendable () -> Date

        public init(
            monotonicNow: @escaping @Sendable () -> TimeInterval,
            wallNow: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.monotonicNowProvider = monotonicNow
            self.wallNowProvider = wallNow
        }

        fileprivate func monotonicNow() -> TimeInterval {
            let value = monotonicNowProvider()
            return value.isFinite ? value : 0
        }

        fileprivate func wallNow() -> Date {
            wallNowProvider()
        }
    }

    public struct NamespaceMetrics: Equatable, Sendable {
        public let hitCount: Int
        public let missCount: Int
        public let memoryEvictionCount: Int
        public let diskEvictionCount: Int
        public let expirationCount: Int

        public init(
            hitCount: Int = 0,
            missCount: Int = 0,
            memoryEvictionCount: Int = 0,
            diskEvictionCount: Int = 0,
            expirationCount: Int = 0
        ) {
            self.hitCount = max(0, hitCount)
            self.missCount = max(0, missCount)
            self.memoryEvictionCount = max(0, memoryEvictionCount)
            self.diskEvictionCount = max(0, diskEvictionCount)
            self.expirationCount = max(0, expirationCount)
        }
    }

    public struct Metrics: Equatable, Sendable {
        public let hitCount: Int
        public let missCount: Int
        public let memoryHitCount: Int
        public let diskHitCount: Int
        public let totalBytes: Int
        public let diskBytes: Int
        public let namespaceMetrics: [Namespace: NamespaceMetrics]

        public init(
            hitCount: Int,
            missCount: Int,
            memoryHitCount: Int = 0,
            diskHitCount: Int = 0,
            totalBytes: Int,
            diskBytes: Int,
            namespaceMetrics: [Namespace: NamespaceMetrics] = [:]
        ) {
            self.hitCount = max(0, hitCount)
            self.missCount = max(0, missCount)
            self.memoryHitCount = max(0, memoryHitCount)
            self.diskHitCount = max(0, diskHitCount)
            self.totalBytes = max(0, totalBytes)
            self.diskBytes = max(0, diskBytes)
            self.namespaceMetrics = namespaceMetrics
        }

        public func metrics(for namespace: Namespace) -> NamespaceMetrics {
            namespaceMetrics[namespace] ?? NamespaceMetrics()
        }
    }

    private struct MutableNamespaceMetrics {
        var hitCount = 0
        var missCount = 0
        var memoryEvictionCount = 0
        var expirationCount = 0
    }

    private var capacityBytes: Int
    private var maximumEntryCount: Int
    private var timeToLive: TimeInterval?
    private let clock: Clock
    private var storage: [String: Data] = [:]
    private var insertionTimes: [String: TimeInterval] = [:]
    private var accessOrder: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    /// Invalidates disk lookups that cross a reentrant write or clear.
    private var dataGeneration: UInt64 = 0
    private var residentBytes = 0
    private var hitCount = 0
    private var missCount = 0
    private var memoryHitCount = 0
    private var diskHitCount = 0
    private var namespaceCounters = Dictionary(
        uniqueKeysWithValues: Namespace.allCases.map { ($0, MutableNamespaceMetrics()) }
    )
    private var diskStore: DiskCacheStore?
    private var diskDirectory: URL?

    public init(
        capacityBytes: Int = 32 * 1024 * 1024,
        diskDirectory: URL? = nil,
        diskCapacityBytes: Int = 512 * 1024 * 1024,
        timeToLive: TimeInterval? = nil,
        maximumEntryCount: Int = 4_096,
        clock: Clock = .continuous
    ) {
        let normalizedTTL = Self.normalizedTTL(timeToLive)
        self.capacityBytes = max(0, capacityBytes)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.timeToLive = normalizedTTL
        self.clock = clock
        self.diskDirectory = diskDirectory
        if let diskDirectory {
            self.diskStore = DiskCacheStore(
                directory: diskDirectory,
                capacityBytes: max(0, diskCapacityBytes),
                timeToLive: normalizedTTL,
                maximumEntryCount: max(1, maximumEntryCount),
                clock: clock
            )
        }
    }

    @available(*, deprecated, message: "Use init(capacityBytes:diskDirectory:diskCapacityBytes:); capacity is measured in bytes.")
    public init(capacity: Int, diskDirectory: URL? = nil) {
        self.init(capacityBytes: capacity, diskDirectory: diskDirectory)
    }

    public func updateConfiguration(
        capacityBytes: Int,
        diskDirectory: URL?,
        diskCapacityBytes: Int = 512 * 1024 * 1024,
        timeToLive: TimeInterval? = nil,
        maximumEntryCount: Int = 4_096
    ) async {
        let normalizedTTL = Self.normalizedTTL(timeToLive)
        let normalizedMaximumEntryCount = max(1, maximumEntryCount)
        self.capacityBytes = max(0, capacityBytes)
        self.timeToLive = normalizedTTL
        self.maximumEntryCount = normalizedMaximumEntryCount
        dataGeneration &+= 1
        if self.diskDirectory != diskDirectory {
            self.diskDirectory = diskDirectory
            self.diskStore = diskDirectory.map {
                DiskCacheStore(
                    directory: $0,
                    capacityBytes: max(0, diskCapacityBytes),
                    timeToLive: normalizedTTL,
                    maximumEntryCount: normalizedMaximumEntryCount,
                    clock: clock
                )
            }
        } else if let diskStore {
            await diskStore.updateConfiguration(
                capacityBytes: max(0, diskCapacityBytes),
                timeToLive: normalizedTTL,
                maximumEntryCount: normalizedMaximumEntryCount
            )
        }
        enforceCapacity()
    }

    @available(*, deprecated, message: "Use updateConfiguration(capacityBytes:diskDirectory:diskCapacityBytes:).")
    public func updateConfiguration(capacity: Int, diskDirectory: URL?) async {
        await updateConfiguration(capacityBytes: capacity, diskDirectory: diskDirectory)
    }

    public func get(_ key: String) async -> Data? {
        let namespace = Namespace.classify(key)
        var foundExpiredEntry = false
        if let value = storage[key] {
            if isExpired(insertionTimes[key]) {
                removeFromMemory(key)
                foundExpiredEntry = true
            } else {
                hitCount += 1
                memoryHitCount += 1
                namespaceCounters[namespace, default: .init()].hitCount += 1
                recordAccess(for: key)
                return value
            }
        }

        if let diskStore {
            let lookupGeneration = dataGeneration
            let lookup = await diskStore.data(for: key)
            guard lookupGeneration == dataGeneration else {
                return await get(key)
            }
            switch lookup {
            case .hit(let data, let age):
                hitCount += 1
                diskHitCount += 1
                namespaceCounters[namespace, default: .init()].hitCount += 1
                insertIntoMemory(
                    data,
                    for: key,
                    insertionTime: clock.monotonicNow() - max(0, age)
                )
                return data
            case .expired:
                foundExpiredEntry = true
            case .missing:
                break
            }
        }

        missCount += 1
        namespaceCounters[namespace, default: .init()].missCount += 1
        if foundExpiredEntry {
            namespaceCounters[namespace, default: .init()].expirationCount += 1
        }
        return nil
    }

    public func put(_ data: Data, for key: String) async {
        dataGeneration &+= 1
        let insertionTime = clock.monotonicNow()
        insertIntoMemory(data, for: key, insertionTime: insertionTime)
        await diskStore?.put(data, for: key, insertionTime: insertionTime)
    }

    public func metrics() async -> Metrics {
        let diskMetrics = await diskStore?.metrics() ?? .empty
        var values: [Namespace: NamespaceMetrics] = [:]
        for namespace in Namespace.allCases {
            let memory = namespaceCounters[namespace] ?? .init()
            values[namespace] = NamespaceMetrics(
                hitCount: memory.hitCount,
                missCount: memory.missCount,
                memoryEvictionCount: memory.memoryEvictionCount,
                diskEvictionCount: diskMetrics.evictionCounts[namespace, default: 0],
                expirationCount: memory.expirationCount
            )
        }
        return Metrics(
            hitCount: hitCount,
            missCount: missCount,
            memoryHitCount: memoryHitCount,
            diskHitCount: diskHitCount,
            totalBytes: residentBytes,
            diskBytes: diskMetrics.byteCount,
            namespaceMetrics: values
        )
    }

    public func clear() async {
        dataGeneration &+= 1
        storage.removeAll(keepingCapacity: false)
        insertionTimes.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        residentBytes = 0
        await diskStore?.clear()
    }

    private func insertIntoMemory(
        _ data: Data,
        for key: String,
        insertionTime: TimeInterval
    ) {
        if let previous = storage.updateValue(data, forKey: key) {
            residentBytes -= previous.count
        }
        insertionTimes[key] = insertionTime
        residentBytes += data.count
        recordAccess(for: key)
        enforceCapacity()
    }

    private func recordAccess(for key: String) {
        accessCounter &+= 1
        accessOrder[key] = accessCounter
    }

    private func isExpired(_ insertionTime: TimeInterval?) -> Bool {
        guard let timeToLive, let insertionTime else { return false }
        return max(0, clock.monotonicNow() - insertionTime) >= timeToLive
    }

    private func removeFromMemory(_ key: String) {
        insertionTimes.removeValue(forKey: key)
        accessOrder.removeValue(forKey: key)
        if let removed = storage.removeValue(forKey: key) {
            residentBytes -= removed.count
        }
    }

    private func enforceCapacity() {
        while residentBytes > capacityBytes || storage.count > maximumEntryCount {
            guard let key = accessOrder.min(by: { $0.value < $1.value })?.key else { break }
            namespaceCounters[Namespace.classify(key), default: .init()].memoryEvictionCount += 1
            removeFromMemory(key)
        }
    }

    private static func normalizedTTL(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

private actor DiskCacheStore {
#if canImport(Dispatch)
    nonisolated private let executor = DiskCacheExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
#endif

    enum Lookup: Sendable {
        case hit(Data, age: TimeInterval)
        case expired
        case missing
    }

    struct Metrics: Sendable {
        static let empty = Metrics(byteCount: 0, evictionCounts: [:])
        let byteCount: Int
        let evictionCounts: [HLSSegmentCache.Namespace: Int]
    }

    private let directory: URL
    private let clock: HLSSegmentCache.Clock
    private var capacityBytes: Int
    private var maximumEntryCount: Int
    private var timeToLive: TimeInterval?
    private let fileManager = FileManager()
    private var knownSizes: [String: Int] = [:]
    private var insertionDates: [String: Date] = [:]
    private var monotonicInsertionTimes: [String: TimeInterval] = [:]
    private var accessOrder: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    private var namespaceByFileName: [String: HLSSegmentCache.Namespace] = [:]
    private var evictionCounts: [HLSSegmentCache.Namespace: Int] = [:]
    private var residentBytes = 0
    private var didLoadMetadata = false

    init(
        directory: URL,
        capacityBytes: Int,
        timeToLive: TimeInterval?,
        maximumEntryCount: Int,
        clock: HLSSegmentCache.Clock
    ) {
        self.directory = directory
        self.capacityBytes = capacityBytes
        self.timeToLive = timeToLive
        self.maximumEntryCount = maximumEntryCount
        self.clock = clock
    }

    func updateConfiguration(
        capacityBytes: Int,
        timeToLive: TimeInterval?,
        maximumEntryCount: Int
    ) {
        self.capacityBytes = capacityBytes
        self.timeToLive = timeToLive
        self.maximumEntryCount = maximumEntryCount
        prepareIfNeeded()
        enforceCapacity()
    }

    func data(for key: String) -> Lookup {
        prepareIfNeeded()
        let fileName = fileName(for: key)
        guard knownSizes[fileName] != nil else { return .missing }
        let age = age(of: fileName)
        if let timeToLive, age >= timeToLive {
            removeFile(named: fileName, recordEviction: false)
            return .expired
        }
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            removeMetadata(for: fileName)
            return .missing
        }
        recordAccess(for: fileName)
        persistAccessDate(for: url)
        return .hit(data, age: age)
    }

    func put(_ data: Data, for key: String, insertionTime: TimeInterval) {
        prepareIfNeeded()
        let fileName = fileName(for: key)
        let url = directory.appendingPathComponent(fileName)
        let wallNow = clock.wallNow()
        do {
            try data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.modificationDate: wallNow], ofItemAtPath: url.path)
            if let previous = knownSizes.updateValue(data.count, forKey: fileName) {
                residentBytes -= previous
            }
            residentBytes += data.count
            insertionDates[fileName] = wallNow
            monotonicInsertionTimes[fileName] = insertionTime
            namespaceByFileName[fileName] = HLSSegmentCache.Namespace.classify(key)
            recordAccess(for: fileName)
            enforceCapacity()
        } catch {
            // Disk caching is optional; an origin fetch remains authoritative.
        }
    }

    func metrics() -> Metrics {
        prepareIfNeeded()
        return Metrics(byteCount: residentBytes, evictionCounts: evictionCounts)
    }

    func clear() {
        prepareIfNeeded()
        for key in knownSizes.keys {
            try? fileManager.removeItem(at: directory.appendingPathComponent(key))
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        knownSizes.removeAll(keepingCapacity: false)
        insertionDates.removeAll(keepingCapacity: false)
        monotonicInsertionTimes.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        namespaceByFileName.removeAll(keepingCapacity: false)
        residentBytes = 0
        didLoadMetadata = true
    }

    private func prepareIfNeeded() {
        guard !didLoadMetadata else { return }
        didLoadMetadata = true
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var ordered: [(url: URL, size: Int, insertionDate: Date, accessDate: Date)] = []
        ordered.reserveCapacity(min(files.count, maximumEntryCount + 1))
        for file in files {
            guard file.lastPathComponent.hasPrefix("hlsproxy-") else { continue }
            guard let values = try? file.resourceValues(forKeys: [
                .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey
            ]) else { continue }
            let insertionDate = values.contentModificationDate ?? .distantPast
            ordered.append((
                url: file,
                size: values.fileSize ?? 0,
                insertionDate: insertionDate,
                accessDate: values.contentAccessDate ?? insertionDate
            ))
        }

        for item in ordered.sorted(by: { $0.accessDate < $1.accessDate }) {
            let fileName = item.url.lastPathComponent
            knownSizes[fileName] = item.size
            insertionDates[fileName] = item.insertionDate
            namespaceByFileName[fileName] = namespace(forFileName: fileName)
            residentBytes += item.size
            recordAccess(for: fileName)
        }
        enforceCapacity()
    }

    private func age(of fileName: String) -> TimeInterval {
        if let insertionTime = monotonicInsertionTimes[fileName] {
            return max(0, clock.monotonicNow() - insertionTime)
        }
        guard let insertionDate = insertionDates[fileName] else { return 0 }
        return max(0, clock.wallNow().timeIntervalSince(insertionDate))
    }

    private func recordAccess(for fileName: String) {
        accessCounter &+= 1
        accessOrder[fileName] = accessCounter
    }

    private func persistAccessDate(for url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.contentAccessDate = clock.wallNow()
        try? mutableURL.setResourceValues(values)
    }

    private func enforceCapacity() {
        while residentBytes > capacityBytes || knownSizes.count > maximumEntryCount {
            guard let fileName = accessOrder.min(by: { $0.value < $1.value })?.key else { break }
            removeFile(named: fileName, recordEviction: true)
        }
    }

    private func removeFile(named fileName: String, recordEviction: Bool) {
        if recordEviction {
            let namespace = namespaceByFileName[fileName] ?? namespace(forFileName: fileName)
            evictionCounts[namespace, default: 0] += 1
        }
        removeMetadata(for: fileName)
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
    }

    private func removeMetadata(for fileName: String) {
        let size = knownSizes.removeValue(forKey: fileName) ?? 0
        residentBytes -= size
        insertionDates.removeValue(forKey: fileName)
        monotonicInsertionTimes.removeValue(forKey: fileName)
        accessOrder.removeValue(forKey: fileName)
        namespaceByFileName.removeValue(forKey: fileName)
    }

    private func namespace(forFileName fileName: String) -> HLSSegmentCache.Namespace {
        guard let key = cacheKey(fromFileName: fileName) else { return .video }
        return HLSSegmentCache.Namespace.classify(key)
    }

    private func fileName(for key: String) -> String {
        "hlsproxy-" + Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    private func cacheKey(fromFileName fileName: String) -> String? {
        guard fileName.hasPrefix("hlsproxy-") else { return nil }
        let encoded = String(fileName.dropFirst("hlsproxy-".count))
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "=")
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

#if canImport(Dispatch)
private final class DiskCacheExecutor: SerialExecutor {
    private let queue = DispatchQueue(
        label: "com.hlsproxybuffer.disk-cache",
        qos: .userInitiated
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async {
            unownedJob.runSynchronously(on: executor)
        }
    }
}
#endif
