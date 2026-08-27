import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

public actor HLSSegmentCache: Caching {
    public struct Metrics: Sendable {
        public let hitCount: Int
        public let missCount: Int
        public let totalBytes: Int
        public let diskBytes: Int

        public init(hitCount: Int, missCount: Int, totalBytes: Int, diskBytes: Int) {
            self.hitCount = hitCount
            self.missCount = missCount
            self.totalBytes = totalBytes
            self.diskBytes = diskBytes
        }
    }

    private var capacityBytes: Int
    private var storage: [String: Data] = [:]
    private var accessOrder: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    private var residentBytes = 0
    private var hitCount = 0
    private var missCount = 0
    private var diskStore: DiskCacheStore?
    private var diskDirectory: URL?

    public init(
        capacityBytes: Int = 32 * 1024 * 1024,
        diskDirectory: URL? = nil,
        diskCapacityBytes: Int = 512 * 1024 * 1024
    ) {
        self.capacityBytes = max(0, capacityBytes)
        self.diskDirectory = diskDirectory
        if let diskDirectory {
            self.diskStore = DiskCacheStore(
                directory: diskDirectory,
                capacityBytes: max(0, diskCapacityBytes)
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
        diskCapacityBytes: Int = 512 * 1024 * 1024
    ) async {
        self.capacityBytes = max(0, capacityBytes)
        if self.diskDirectory != diskDirectory {
            self.diskDirectory = diskDirectory
            self.diskStore = diskDirectory.map {
                DiskCacheStore(directory: $0, capacityBytes: max(0, diskCapacityBytes))
            }
        } else if let diskStore {
            await diskStore.updateCapacity(max(0, diskCapacityBytes))
        }
        enforceCapacity()
    }

    @available(*, deprecated, message: "Use updateConfiguration(capacityBytes:diskDirectory:diskCapacityBytes:).")
    public func updateConfiguration(capacity: Int, diskDirectory: URL?) async {
        await updateConfiguration(capacityBytes: capacity, diskDirectory: diskDirectory)
    }

    public func get(_ key: String) async -> Data? {
        if let value = storage[key] {
            hitCount += 1
            recordAccess(for: key)
            return value
        }

        if let diskData = await diskStore?.data(for: key) {
            hitCount += 1
            insertIntoMemory(diskData, for: key)
            return diskData
        }

        missCount += 1
        return nil
    }

    public func put(_ data: Data, for key: String) async {
        insertIntoMemory(data, for: key)
        await diskStore?.put(data, for: key)
    }

    public func metrics() async -> Metrics {
        Metrics(
            hitCount: hitCount,
            missCount: missCount,
            totalBytes: residentBytes,
            diskBytes: await diskStore?.byteCount() ?? 0
        )
    }

    public func clear() async {
        storage.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        residentBytes = 0
        await diskStore?.clear()
    }

    private func insertIntoMemory(_ data: Data, for key: String) {
        if let previous = storage.updateValue(data, forKey: key) {
            residentBytes -= previous.count
        }
        residentBytes += data.count
        recordAccess(for: key)
        enforceCapacity()
    }

    private func recordAccess(for key: String) {
        accessCounter &+= 1
        accessOrder[key] = accessCounter
    }

    private func enforceCapacity() {
        while residentBytes > capacityBytes,
              let key = accessOrder.min(by: { $0.value < $1.value })?.key {
            accessOrder.removeValue(forKey: key)
            if let removed = storage.removeValue(forKey: key) {
                residentBytes -= removed.count
            }
        }
    }
}

private actor DiskCacheStore {
#if canImport(Dispatch)
    nonisolated private let executor = DiskCacheExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
#endif

    private let directory: URL
    private var capacityBytes: Int
    private let fileManager = FileManager()
    private var knownSizes: [String: Int] = [:]
    private var accessDates: [String: Date] = [:]
    private var residentBytes = 0
    private var didLoadMetadata = false

    init(directory: URL, capacityBytes: Int) {
        self.directory = directory
        self.capacityBytes = capacityBytes
    }

    func updateCapacity(_ capacityBytes: Int) {
        self.capacityBytes = capacityBytes
        prepareIfNeeded()
        enforceCapacity()
    }

    func data(for key: String) -> Data? {
        prepareIfNeeded()
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        accessDates[fileName(for: key)] = Date()
        return data
    }

    func put(_ data: Data, for key: String) {
        prepareIfNeeded()
        let fileName = fileName(for: key)
        do {
            try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
            if let previous = knownSizes.updateValue(data.count, forKey: fileName) {
                residentBytes -= previous
            }
            residentBytes += data.count
            accessDates[fileName] = Date()
            enforceCapacity()
        } catch {
            // Disk caching is optional; an origin fetch remains authoritative.
        }
    }

    func byteCount() -> Int {
        prepareIfNeeded()
        return residentBytes
    }

    func clear() {
        prepareIfNeeded()
        for key in knownSizes.keys {
            try? fileManager.removeItem(at: directory.appendingPathComponent(key))
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        knownSizes.removeAll(keepingCapacity: false)
        accessDates.removeAll(keepingCapacity: false)
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
        for file in files {
            guard file.lastPathComponent.hasPrefix("hlsproxy-") else { continue }
            guard let values = try? file.resourceValues(forKeys: [
                .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey
            ]) else { continue }
            let key = file.lastPathComponent
            let size = values.fileSize ?? 0
            knownSizes[key] = size
            accessDates[key] = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            residentBytes += size
        }
        enforceCapacity()
    }

    private func enforceCapacity() {
        while residentBytes > capacityBytes,
              let key = accessDates.min(by: { $0.value < $1.value })?.key {
            accessDates.removeValue(forKey: key)
            let size = knownSizes.removeValue(forKey: key) ?? 0
            residentBytes -= size
            try? fileManager.removeItem(at: directory.appendingPathComponent(key))
        }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(fileName(for: key))
    }

    private func fileName(for key: String) -> String {
        "hlsproxy-" + Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
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
