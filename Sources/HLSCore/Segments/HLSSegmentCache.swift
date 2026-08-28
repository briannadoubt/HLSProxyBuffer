import Foundation
import CryptoKit
#if canImport(Dispatch)
import Dispatch
#endif

public actor HLSSegmentCache: Caching {
    /// Origin validators and freshness attached to cached HTTP bytes. These
    /// values are persisted beside disk entries and contain no request headers,
    /// credentials, or query-derived telemetry.
    public struct ValidationMetadata: Codable, Equatable, Sendable {
        private static let maximumValidatorCharacters = 512

        public let eTag: String?
        public let lastModified: String?
        public let freshUntil: Date?

        public init(
            eTag: String? = nil,
            lastModified: String? = nil,
            freshUntil: Date? = nil
        ) {
            self.eTag = Self.normalizedValidator(eTag)
            self.lastModified = Self.normalizedValidator(lastModified)
            self.freshUntil = freshUntil.flatMap {
                $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                eTag: try container.decodeIfPresent(String.self, forKey: .eTag),
                lastModified: try container.decodeIfPresent(String.self, forKey: .lastModified),
                freshUntil: try container.decodeIfPresent(Date.self, forKey: .freshUntil)
            )
        }

        private static func normalizedValidator(_ value: String?) -> String? {
            guard let value,
                  !value.unicodeScalars.contains(where: {
                      $0.value < 0x20 || $0.value == 0x7F
                  })
            else { return nil }
            return String(value.prefix(maximumValidatorCharacters))
        }
    }

    public struct Entry: Equatable, Sendable {
        public let data: Data
        public let validation: ValidationMetadata?
        public let isExpired: Bool

        public init(
            data: Data,
            validation: ValidationMetadata? = nil,
            isExpired: Bool = false
        ) {
            self.data = data
            self.validation = validation
            self.isExpired = isExpired
        }
    }

    /// Fixed-cardinality reasons why an entry left a cache tier.
    public enum EvictionReason: String, CaseIterable, Hashable, Sendable {
        case memoryByteLimit = "memory_byte_limit"
        case memoryEntryLimit = "memory_entry_limit"
        case memoryPressure = "memory_pressure"
        case diskByteLimit = "disk_byte_limit"
        case diskEntryLimit = "disk_entry_limit"
        case originPolicy = "origin_policy"
        case expired
    }

    /// A fixed-cardinality classification for cache telemetry.
    public enum Namespace: String, CaseIterable, Codable, Hashable, Sendable {
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
        public let memoryEntryCount: Int
        public let diskEntryCount: Int
        public let memoryHighWaterBytes: Int
        public let diskHighWaterBytes: Int
        public let evictionCounts: [EvictionReason: Int]
        public let namespaceMetrics: [Namespace: NamespaceMetrics]

        public init(
            hitCount: Int,
            missCount: Int,
            memoryHitCount: Int = 0,
            diskHitCount: Int = 0,
            totalBytes: Int,
            diskBytes: Int,
            memoryEntryCount: Int = 0,
            diskEntryCount: Int = 0,
            memoryHighWaterBytes: Int = 0,
            diskHighWaterBytes: Int = 0,
            evictionCounts: [EvictionReason: Int] = [:],
            namespaceMetrics: [Namespace: NamespaceMetrics] = [:]
        ) {
            self.hitCount = max(0, hitCount)
            self.missCount = max(0, missCount)
            self.memoryHitCount = max(0, memoryHitCount)
            self.diskHitCount = max(0, diskHitCount)
            self.totalBytes = max(0, totalBytes)
            self.diskBytes = max(0, diskBytes)
            self.memoryEntryCount = max(0, memoryEntryCount)
            self.diskEntryCount = max(0, diskEntryCount)
            self.memoryHighWaterBytes = max(self.totalBytes, memoryHighWaterBytes)
            self.diskHighWaterBytes = max(self.diskBytes, diskHighWaterBytes)
            self.evictionCounts = evictionCounts.mapValues { max(0, $0) }
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
    private var validationByKey: [String: ValidationMetadata] = [:]
    private var insertionTimes: [String: TimeInterval] = [:]
    private var accessOrder: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    /// Invalidates disk lookups that cross a reentrant write or clear.
    private var dataGeneration: UInt64 = 0
    /// Prevents a disk read already in flight from repopulating memory after a
    /// pressure response while still allowing that caller to consume the bytes.
    private var memoryPressureGeneration: UInt64 = 0
    private var residentBytes = 0
    private var memoryHighWaterBytes = 0
    private var hitCount = 0
    private var missCount = 0
    private var memoryHitCount = 0
    private var diskHitCount = 0
    private var evictionCounts: [EvictionReason: Int] = [:]
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
        await entry(for: key)?.data
    }

    /// Returns one cache entry. Callers that can perform conditional HTTP
    /// revalidation may opt into expired bytes and use their persisted ETag or
    /// Last-Modified value; ordinary cache reads continue to reject stale data.
    public func entry(for key: String, allowingExpired: Bool = false) async -> Entry? {
        let namespace = Namespace.classify(key)
        var foundExpiredEntry = false
        if let value = storage[key] {
            let validation = validationByKey[key]
            if isExpired(insertionTimes[key], validation: validation) {
                foundExpiredEntry = true
                if allowingExpired {
                    recordExpiration(for: namespace)
                    return Entry(data: value, validation: validation, isExpired: true)
                }
                evictionCounts[.expired, default: 0] += 1
                removeFromMemory(key)
            } else {
                hitCount += 1
                memoryHitCount += 1
                namespaceCounters[namespace, default: .init()].hitCount += 1
                recordAccess(for: key)
                return Entry(data: value, validation: validation)
            }
        }

        if let diskStore {
            let lookupGeneration = dataGeneration
            let lookupMemoryPressureGeneration = memoryPressureGeneration
            let lookup = await diskStore.data(for: key, allowingExpired: allowingExpired)
            guard lookupGeneration == dataGeneration else {
                return await entry(for: key, allowingExpired: allowingExpired)
            }
            switch lookup {
            case .hit(let data, let age, let validation):
                hitCount += 1
                diskHitCount += 1
                namespaceCounters[namespace, default: .init()].hitCount += 1
                if lookupMemoryPressureGeneration == memoryPressureGeneration {
                    insertIntoMemory(
                        data,
                        for: key,
                        insertionTime: clock.monotonicNow() - max(0, age),
                        validation: validation
                    )
                }
                return Entry(data: data, validation: validation)
            case .expired(let data, let validation):
                foundExpiredEntry = true
                if allowingExpired, let data {
                    recordExpiration(for: namespace)
                    return Entry(data: data, validation: validation, isExpired: true)
                }
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
        await put(data, for: key, validation: nil)
    }

    public func put(
        _ data: Data,
        for key: String,
        validation: ValidationMetadata?
    ) async {
        dataGeneration &+= 1
        let insertionTime = clock.monotonicNow()
        insertIntoMemory(
            data,
            for: key,
            insertionTime: insertionTime,
            validation: validation
        )
        await diskStore?.put(
            data,
            for: key,
            insertionTime: insertionTime,
            validation: validation
        )
    }

    /// Removes one key from every tier, for example when an origin responds
    /// with `Cache-Control: no-store` during revalidation.
    public func remove(_ key: String) async {
        dataGeneration &+= 1
        if storage[key] != nil {
            namespaceCounters[Namespace.classify(key), default: .init()].memoryEvictionCount += 1
            evictionCounts[.originPolicy, default: 0] += 1
            removeFromMemory(key)
        }
        await diskStore?.remove(key, reason: .originPolicy)
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
            memoryEntryCount: storage.count,
            diskEntryCount: diskMetrics.entryCount,
            memoryHighWaterBytes: memoryHighWaterBytes,
            diskHighWaterBytes: diskMetrics.highWaterBytes,
            evictionCounts: evictionCounts.merging(diskMetrics.reasonCounts, uniquingKeysWith: +),
            namespaceMetrics: values
        )
    }

    /// Immediately drops memory-resident bytes while preserving valid disk
    /// entries. Platform lifecycle adapters can call this in response to a
    /// memory-pressure notification without exposing cache ownership to UI code.
    public func handleMemoryPressure() {
        memoryPressureGeneration &+= 1
        for key in storage.keys {
            namespaceCounters[Namespace.classify(key), default: .init()].memoryEvictionCount += 1
            evictionCounts[.memoryPressure, default: 0] += 1
        }
        storage.removeAll(keepingCapacity: false)
        validationByKey.removeAll(keepingCapacity: false)
        insertionTimes.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        residentBytes = 0
    }

    public func clear() async {
        dataGeneration &+= 1
        storage.removeAll(keepingCapacity: false)
        validationByKey.removeAll(keepingCapacity: false)
        insertionTimes.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        residentBytes = 0
        await diskStore?.clear()
    }

    private func insertIntoMemory(
        _ data: Data,
        for key: String,
        insertionTime: TimeInterval,
        validation: ValidationMetadata? = nil
    ) {
        if let previous = storage.updateValue(data, forKey: key) {
            residentBytes -= previous.count
        }
        insertionTimes[key] = insertionTime
        validationByKey[key] = validation
        residentBytes += data.count
        memoryHighWaterBytes = max(memoryHighWaterBytes, residentBytes)
        recordAccess(for: key)
        enforceCapacity()
    }

    private func recordAccess(for key: String) {
        accessCounter &+= 1
        accessOrder[key] = accessCounter
    }

    private func isExpired(
        _ insertionTime: TimeInterval?,
        validation: ValidationMetadata?
    ) -> Bool {
        if let freshUntil = validation?.freshUntil,
           clock.wallNow() >= freshUntil {
            return true
        }
        guard let timeToLive, let insertionTime else { return false }
        return max(0, clock.monotonicNow() - insertionTime) >= timeToLive
    }

    private func removeFromMemory(_ key: String) {
        insertionTimes.removeValue(forKey: key)
        validationByKey.removeValue(forKey: key)
        accessOrder.removeValue(forKey: key)
        if let removed = storage.removeValue(forKey: key) {
            residentBytes -= removed.count
        }
    }

    private func recordExpiration(for namespace: Namespace) {
        missCount += 1
        namespaceCounters[namespace, default: .init()].missCount += 1
        namespaceCounters[namespace, default: .init()].expirationCount += 1
    }

    private func enforceCapacity() {
        while residentBytes > capacityBytes || storage.count > maximumEntryCount {
            guard let key = accessOrder.min(by: { $0.value < $1.value })?.key else { break }
            let reason: EvictionReason = residentBytes > capacityBytes
                ? .memoryByteLimit
                : .memoryEntryLimit
            evictionCounts[reason, default: 0] += 1
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
        case hit(Data, age: TimeInterval, validation: HLSSegmentCache.ValidationMetadata?)
        case expired(Data?, validation: HLSSegmentCache.ValidationMetadata?)
        case missing
    }

    private struct PersistedMetadata: Codable, Sendable {
        let namespace: HLSSegmentCache.Namespace
        let validation: HLSSegmentCache.ValidationMetadata?
    }

    struct Metrics: Sendable {
        static let empty = Metrics(
            byteCount: 0,
            entryCount: 0,
            highWaterBytes: 0,
            evictionCounts: [:],
            reasonCounts: [:]
        )
        let byteCount: Int
        let entryCount: Int
        let highWaterBytes: Int
        let evictionCounts: [HLSSegmentCache.Namespace: Int]
        let reasonCounts: [HLSSegmentCache.EvictionReason: Int]
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
    private var reasonCounts: [HLSSegmentCache.EvictionReason: Int] = [:]
    private var residentBytes = 0
    private var highWaterBytes = 0
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

    func data(for key: String, allowingExpired: Bool) -> Lookup {
        prepareIfNeeded()
        let fileName = resolvedFileName(for: key)
        guard knownSizes[fileName] != nil else { return .missing }
        let age = age(of: fileName)
        let validation = persistedMetadata(for: fileName)?.validation
        if isExpired(age: age, validation: validation) {
            if allowingExpired {
                let url = directory.appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                    removeMetadata(for: fileName)
                    return .missing
                }
                return .expired(data, validation: validation)
            }
            removeFile(named: fileName, reason: .expired)
            return .expired(nil, validation: validation)
        }
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            removeMetadata(for: fileName)
            return .missing
        }
        recordAccess(for: fileName)
        persistAccessDate(for: url)
        return .hit(data, age: age, validation: validation)
    }

    func put(
        _ data: Data,
        for key: String,
        insertionTime: TimeInterval,
        validation: HLSSegmentCache.ValidationMetadata?
    ) {
        prepareIfNeeded()
        let fileName = resolvedFileName(for: key)
        let url = directory.appendingPathComponent(fileName)
        let wallNow = clock.wallNow()
        do {
            try data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes([.modificationDate: wallNow], ofItemAtPath: url.path)
            if let previous = knownSizes.updateValue(data.count, forKey: fileName) {
                residentBytes -= previous
            }
            residentBytes += data.count
            highWaterBytes = max(highWaterBytes, residentBytes)
            insertionDates[fileName] = wallNow
            monotonicInsertionTimes[fileName] = insertionTime
            namespaceByFileName[fileName] = HLSSegmentCache.Namespace.classify(key)
            persist(
                validation: validation,
                namespace: HLSSegmentCache.Namespace.classify(key),
                for: fileName
            )
            recordAccess(for: fileName)
            enforceCapacity()
        } catch {
            // Disk caching is optional; an origin fetch remains authoritative.
        }
    }

    func metrics() -> Metrics {
        prepareIfNeeded()
        return Metrics(
            byteCount: residentBytes,
            entryCount: knownSizes.count,
            highWaterBytes: highWaterBytes,
            evictionCounts: evictionCounts,
            reasonCounts: reasonCounts
        )
    }

    func clear() {
        prepareIfNeeded()
        for key in knownSizes.keys {
            try? fileManager.removeItem(at: directory.appendingPathComponent(key))
            try? fileManager.removeItem(at: validationURL(for: key))
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

    func remove(_ key: String, reason: HLSSegmentCache.EvictionReason) {
        prepareIfNeeded()
        let fileName = resolvedFileName(for: key)
        guard knownSizes[fileName] != nil else { return }
        removeFile(named: fileName, reason: reason)
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
            namespaceByFileName[fileName] = persistedMetadata(for: fileName)?.namespace
                ?? namespace(forFileName: fileName)
            residentBytes += item.size
            highWaterBytes = max(highWaterBytes, residentBytes)
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

    private func isExpired(
        age: TimeInterval,
        validation: HLSSegmentCache.ValidationMetadata?
    ) -> Bool {
        if let freshUntil = validation?.freshUntil,
           clock.wallNow() >= freshUntil {
            return true
        }
        return timeToLive.map { age >= $0 } ?? false
    }

    private func persistedMetadata(for fileName: String) -> PersistedMetadata? {
        guard let data = try? Data(contentsOf: validationURL(for: fileName)) else {
            return nil
        }
        if let metadata = try? JSONDecoder().decode(PersistedMetadata.self, from: data) {
            return metadata
        }
        // Compatibility with validator-only sidecars written by early builds.
        guard let validation = try? JSONDecoder().decode(
            HLSSegmentCache.ValidationMetadata.self,
            from: data
        ) else { return nil }
        return PersistedMetadata(
            namespace: namespace(forFileName: fileName),
            validation: validation
        )
    }

    private func persist(
        validation: HLSSegmentCache.ValidationMetadata?,
        namespace: HLSSegmentCache.Namespace,
        for fileName: String
    ) {
        let url = validationURL(for: fileName)
        let metadata = PersistedMetadata(namespace: namespace, validation: validation)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func validationURL(for fileName: String) -> URL {
        directory.appendingPathComponent(".\(fileName).validation.json")
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
            let reason: HLSSegmentCache.EvictionReason = residentBytes > capacityBytes
                ? .diskByteLimit
                : .diskEntryLimit
            removeFile(named: fileName, reason: reason)
        }
    }

    private func removeFile(
        named fileName: String,
        reason: HLSSegmentCache.EvictionReason?
    ) {
        if let reason {
            reasonCounts[reason, default: 0] += 1
        }
        if reason == .diskByteLimit || reason == .diskEntryLimit {
            let namespace = namespaceByFileName[fileName] ?? namespace(forFileName: fileName)
            evictionCounts[namespace, default: 0] += 1
        }
        removeMetadata(for: fileName)
        try? fileManager.removeItem(at: directory.appendingPathComponent(fileName))
        try? fileManager.removeItem(at: validationURL(for: fileName))
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
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "hlsproxy-v2-\(digest)"
    }

    private func resolvedFileName(for key: String) -> String {
        let current = fileName(for: key)
        if knownSizes[current] != nil { return current }
        let legacy = legacyFileName(for: key)
        return knownSizes[legacy] == nil ? current : legacy
    }

    private func legacyFileName(for key: String) -> String {
        "hlsproxy-" + Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    private func cacheKey(fromFileName fileName: String) -> String? {
        guard fileName.hasPrefix("hlsproxy-"),
              !fileName.hasPrefix("hlsproxy-v2-")
        else { return nil }
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
