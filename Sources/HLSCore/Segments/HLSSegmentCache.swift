import Foundation

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

    private var capacity: Int
    private var storage: [String: Data] = [:]
    private var order: [String] = []
    private var hitCount = 0
    private var missCount = 0
    private var diskDirectory: URL?
    private let fileManager = FileManager()

    public init(capacity: Int = 32, diskDirectory: URL? = nil) {
        self.capacity = capacity
        self.diskDirectory = diskDirectory
        if let diskDirectory {
            try? fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
    }

    public func updateConfiguration(capacity: Int, diskDirectory: URL?) {
        self.capacity = capacity
        self.diskDirectory = diskDirectory
        ensureDiskDirectory()
        enforceCapacity()
    }

    public func get(_ key: String) async -> Data? {
        if let value = storage[key] {
            hitCount += 1
            moveKeyToFront(key)
            return value
        }

        if let directory = diskDirectory,
           let diskData = try? Data(contentsOf: fileURL(for: key, directory: directory)) {
            hitCount += 1
            storage[key] = diskData
            moveKeyToFront(key)
            enforceCapacity()
            return diskData
        }

        missCount += 1
        return nil
    }

    public func put(_ data: Data, for key: String) async {
        storage[key] = data
        moveKeyToFront(key)
        enforceCapacity()

        guard let directory = diskDirectory else { return }
        do {
            try data.write(to: fileURL(for: key, directory: directory), options: [.atomic])
        } catch {
            // Disk caching is best-effort; ignore write failures in MVP.
        }
    }

    public func metrics() -> Metrics {
        let diskBytes: Int
        if let directory = diskDirectory, let contents = try? fileManager
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            diskBytes = contents.reduce(0) { partial, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return partial + (values?.fileSize ?? 0)
            }
        } else {
            diskBytes = 0
        }

        return Metrics(
            hitCount: hitCount,
            missCount: missCount,
            totalBytes: storage.values.reduce(0) { $0 + $1.count },
            diskBytes: diskBytes
        )
    }

    private func moveKeyToFront(_ key: String) {
        order.removeAll(where: { $0 == key })
        order.insert(key, at: 0)
    }

    private func enforceCapacity() {
        while order.count > capacity, let key = order.popLast() {
            storage.removeValue(forKey: key)
        }
    }

    private func ensureDiskDirectory() {
        guard let diskDirectory else { return }
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
}
