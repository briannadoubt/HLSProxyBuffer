import Foundation

public actor HLSSegmentCache: Caching {
    public enum SegmentType: String, Sendable, CaseIterable {
        case video
        case audio
        case subtitle
        case unknown
    }

    public struct CacheEntry: Sendable {
        public let data: Data
        public let namespace: String
        public let segmentType: SegmentType
        public let insertedAt: Date
        public let lastAccessedAt: Date
        public let byteCount: Int

        init(data: Data, namespace: String, segmentType: SegmentType, now: Date = Date()) {
            self.data = data
            self.namespace = namespace
            self.segmentType = segmentType
            self.insertedAt = now
            self.lastAccessedAt = now
            self.byteCount = data.count
        }

        func accessed(at time: Date) -> CacheEntry {
            CacheEntry(
                data: data,
                namespace: namespace,
                segmentType: segmentType,
                insertedAt: insertedAt,
                lastAccessedAt: time,
                byteCount: byteCount
            )
        }
    }

    public struct Metrics: Sendable {
        public let hitCount: Int
        public let missCount: Int
        public let totalBytes: Int
        public let diskBytes: Int
        public let hitCountByType: [SegmentType: Int]
        public let missCountByType: [SegmentType: Int]
        public let bytesByNamespace: [String: Int]
        public let entryCount: Int
        public let evictionCount: Int
        public let hitRate: Double

        public init(
            hitCount: Int,
            missCount: Int,
            totalBytes: Int,
            diskBytes: Int,
            hitCountByType: [SegmentType: Int] = [:],
            missCountByType: [SegmentType: Int] = [:],
            bytesByNamespace: [String: Int] = [:],
            entryCount: Int = 0,
            evictionCount: Int = 0
        ) {
            self.hitCount = hitCount
            self.missCount = missCount
            self.totalBytes = totalBytes
            self.diskBytes = diskBytes
            self.hitCountByType = hitCountByType
            self.missCountByType = missCountByType
            self.bytesByNamespace = bytesByNamespace
            self.entryCount = entryCount
            self.evictionCount = evictionCount
            let total = hitCount + missCount
            self.hitRate = total > 0 ? Double(hitCount) / Double(total) : 0
        }
    }

    public struct Configuration: Sendable {
        public var memoryCapacity: Int
        public var memoryCapacityByNamespace: [String: Int]?
        public var maxMemoryBytes: Int?
        public var diskDirectory: URL?
        public var diskQuotaBytes: Int?
        public var expirationInterval: TimeInterval?
        public var persistAcrossSessions: Bool

        public init(
            memoryCapacity: Int = 32,
            memoryCapacityByNamespace: [String: Int]? = nil,
            maxMemoryBytes: Int? = nil,
            diskDirectory: URL? = nil,
            diskQuotaBytes: Int? = nil,
            expirationInterval: TimeInterval? = nil,
            persistAcrossSessions: Bool = false
        ) {
            self.memoryCapacity = memoryCapacity
            self.memoryCapacityByNamespace = memoryCapacityByNamespace
            self.maxMemoryBytes = maxMemoryBytes
            self.diskDirectory = diskDirectory
            self.diskQuotaBytes = diskQuotaBytes
            self.expirationInterval = expirationInterval
            self.persistAcrossSessions = persistAcrossSessions
        }
    }

    private var configuration: Configuration
    private var storage: [String: CacheEntry] = [:]
    private var orderByNamespace: [String: [String]] = [:]
    private var globalOrder: [String] = []
    private var hitCount = 0
    private var missCount = 0
    private var hitCountByType: [SegmentType: Int] = [:]
    private var missCountByType: [SegmentType: Int] = [:]
    private var evictionCount = 0
    private let fileManager = FileManager()
    private var expirationTimer: Task<Void, Never>?

    public init(capacity: Int = 32, diskDirectory: URL? = nil) {
        self.configuration = Configuration(
            memoryCapacity: capacity,
            diskDirectory: diskDirectory
        )
        if let diskDirectory {
            try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        ensureDiskDirectory()
        if configuration.persistAcrossSessions {
            Task { await loadPersistedCache() }
        }
        if configuration.expirationInterval != nil {
            startExpirationTimer()
        }
    }

    public func updateConfiguration(capacity: Int, diskDirectory: URL?) {
        configuration.memoryCapacity = capacity
        configuration.diskDirectory = diskDirectory
        ensureDiskDirectory()
        enforceCapacity()
    }

    public func updateConfiguration(_ newConfig: Configuration) {
        configuration = newConfig
        ensureDiskDirectory()
        enforceCapacity()
        enforceDiskQuota()

        if configuration.expirationInterval != nil && expirationTimer == nil {
            startExpirationTimer()
        } else if configuration.expirationInterval == nil {
            expirationTimer?.cancel()
            expirationTimer = nil
        }
    }

    public func get(_ key: String) async -> Data? {
        await get(key, namespace: "default", segmentType: .unknown)
    }

    public func get(_ key: String, namespace: String = "default", segmentType: SegmentType = .unknown) async -> Data? {
        // Check for expired entry
        if let entry = storage[key] {
            if let expiration = configuration.expirationInterval,
               Date().timeIntervalSince(entry.insertedAt) > expiration {
                // Entry expired, remove it
                removeEntry(forKey: key)
                recordMiss(type: segmentType)
                return nil
            }

            recordHit(type: entry.segmentType)
            storage[key] = entry.accessed(at: Date())
            moveKeyToFront(key, namespace: entry.namespace)
            return entry.data
        }

        // Try disk cache
        if let directory = configuration.diskDirectory,
           let diskData = try? Data(contentsOf: fileURL(for: key, directory: directory)) {
            recordHit(type: segmentType)
            let entry = CacheEntry(data: diskData, namespace: namespace, segmentType: segmentType)
            storage[key] = entry
            moveKeyToFront(key, namespace: namespace)
            enforceCapacity()
            return diskData
        }

        recordMiss(type: segmentType)
        return nil
    }

    public func put(_ data: Data, for key: String) async {
        await put(data, for: key, namespace: "default", segmentType: .unknown)
    }

    public func put(_ data: Data, for key: String, namespace: String = "default", segmentType: SegmentType = .unknown) async {
        let entry = CacheEntry(data: data, namespace: namespace, segmentType: segmentType)
        storage[key] = entry
        moveKeyToFront(key, namespace: namespace)
        enforceCapacity()
        enforceMemoryBytes()

        guard let directory = configuration.diskDirectory else { return }
        do {
            try data.write(to: fileURL(for: key, directory: directory), options: [.atomic])
            enforceDiskQuota()
        } catch {
            // Disk caching is best-effort
        }
    }

    public func prewarm(keys: [String], fetcher: @Sendable (String) async -> Data?) async {
        for key in keys {
            if storage[key] != nil { continue }
            if let data = await fetcher(key) {
                await put(data, for: key)
            }
        }
    }

    public func prewarm(segments: [HLSSegment], fetcher: any SegmentSource) async {
        for segment in segments {
            let key = SegmentIdentity.key(for: segment)
            if storage[key] != nil { continue }
            do {
                let data = try await fetcher.fetchSegment(segment)
                await put(data, for: key, namespace: "primary", segmentType: .video)
            } catch {
                // Prewarm failures are non-critical
            }
        }
    }

    public func metrics() -> Metrics {
        let diskBytes: Int
        if let directory = configuration.diskDirectory,
           let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            diskBytes = contents.reduce(0) { partial, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return partial + (values?.fileSize ?? 0)
            }
        } else {
            diskBytes = 0
        }

        var bytesByNamespace: [String: Int] = [:]
        for (_, entry) in storage {
            bytesByNamespace[entry.namespace, default: 0] += entry.byteCount
        }

        return Metrics(
            hitCount: hitCount,
            missCount: missCount,
            totalBytes: storage.values.reduce(0) { $0 + $1.byteCount },
            diskBytes: diskBytes,
            hitCountByType: hitCountByType,
            missCountByType: missCountByType,
            bytesByNamespace: bytesByNamespace,
            entryCount: storage.count,
            evictionCount: evictionCount
        )
    }

    public func clear() {
        storage.removeAll()
        orderByNamespace.removeAll()
        globalOrder.removeAll()
        if let directory = configuration.diskDirectory, !configuration.persistAcrossSessions {
            try? fileManager.removeItem(at: directory)
            ensureDiskDirectory()
        }
    }

    public func clearNamespace(_ namespace: String) {
        let keysToRemove = storage.filter { $0.value.namespace == namespace }.map(\.key)
        for key in keysToRemove {
            removeEntry(forKey: key)
        }
    }

    public func evictExpired() {
        guard let expiration = configuration.expirationInterval else { return }
        let now = Date()
        let keysToRemove = storage.filter { now.timeIntervalSince($0.value.insertedAt) > expiration }.map(\.key)
        for key in keysToRemove {
            removeEntry(forKey: key)
            evictionCount += 1
        }
    }

    public func entryCount(for namespace: String) -> Int {
        storage.values.filter { $0.namespace == namespace }.count
    }

    public func totalBytes(for namespace: String) -> Int {
        storage.values.filter { $0.namespace == namespace }.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - Private Methods

    private func recordHit(type: SegmentType) {
        hitCount += 1
        hitCountByType[type, default: 0] += 1
    }

    private func recordMiss(type: SegmentType) {
        missCount += 1
        missCountByType[type, default: 0] += 1
    }

    private func removeEntry(forKey key: String) {
        if let entry = storage.removeValue(forKey: key) {
            if var order = orderByNamespace[entry.namespace] {
                order.removeAll { $0 == key }
                if order.isEmpty {
                    orderByNamespace.removeValue(forKey: entry.namespace)
                } else {
                    orderByNamespace[entry.namespace] = order
                }
            }
            globalOrder.removeAll { $0 == key }
        }
    }

    private func moveKeyToFront(_ key: String, namespace: String) {
        // Update namespace-specific order
        var order = orderByNamespace[namespace] ?? []
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        orderByNamespace[namespace] = order

        // Update global order
        globalOrder.removeAll { $0 == key }
        globalOrder.insert(key, at: 0)
    }

    private func enforceCapacity() {
        // Enforce per-namespace capacity if configured
        if let capacityByNamespace = configuration.memoryCapacityByNamespace {
            for (namespace, maxCapacity) in capacityByNamespace {
                while let order = orderByNamespace[namespace], order.count > maxCapacity, let key = order.last {
                    removeEntry(forKey: key)
                    evictionCount += 1
                }
            }
        }

        // Enforce global capacity
        while globalOrder.count > configuration.memoryCapacity, let key = globalOrder.last {
            removeEntry(forKey: key)
            evictionCount += 1
        }
    }

    private func enforceMemoryBytes() {
        guard let maxBytes = configuration.maxMemoryBytes else { return }
        var totalBytes = storage.values.reduce(0) { $0 + $1.byteCount }

        while totalBytes > maxBytes, let key = globalOrder.last {
            if let entry = storage[key] {
                totalBytes -= entry.byteCount
            }
            removeEntry(forKey: key)
            evictionCount += 1
        }
    }

    private func enforceDiskQuota() {
        guard let directory = configuration.diskDirectory,
              let quota = configuration.diskQuotaBytes else { return }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var totalSize = 0
        var fileInfos: [(url: URL, size: Int, date: Date)] = []

        for url in contents {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = values.fileSize ?? 0
            let date = values.contentModificationDate ?? Date.distantPast
            totalSize += size
            fileInfos.append((url, size, date))
        }

        if totalSize <= quota { return }

        // Sort by date (oldest first) and remove until under quota
        fileInfos.sort { $0.date < $1.date }
        for info in fileInfos {
            if totalSize <= quota { break }
            try? fileManager.removeItem(at: info.url)
            totalSize -= info.size
        }
    }

    private func ensureDiskDirectory() {
        guard let diskDirectory = configuration.diskDirectory else { return }
        try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String, directory: URL) -> URL {
        directory.appendingPathComponent(safeFileComponent(for: key))
    }

    private func safeFileComponent(for key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    private func startExpirationTimer() {
        expirationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
                await self?.evictExpired()
            }
        }
    }

    private func loadPersistedCache() async {
        guard let directory = configuration.diskDirectory else { return }
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }

        for url in contents {
            guard let data = try? Data(contentsOf: url) else { continue }
            let filename = url.lastPathComponent
            let key = decodeKey(from: filename)
            let entry = CacheEntry(data: data, namespace: "persisted", segmentType: .unknown)
            storage[key] = entry
            moveKeyToFront(key, namespace: "persisted")
        }

        enforceCapacity()
    }

    private func decodeKey(from filename: String) -> String {
        let base64 = filename
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "=")
        guard let data = Data(base64Encoded: base64),
              let key = String(data: data, encoding: .utf8) else {
            return filename
        }
        return key
    }
}
