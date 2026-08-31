import Foundation

/// Qualification must create real origin work even after a previous test warmed
/// every clip. Normal launches continue to use the engine's persistent cache.
enum FeedDemoCacheScope: Equatable, Sendable {
    case persistent
    case freshQualification

    func prepareDirectory(in cacheRoot: URL = URL.cachesDirectory) throws -> URL? {
        guard self == .freshQualification else { return nil }
        // This reserved directory contains only generated qualification bytes.
        // Never clear the ordinary HLSProxyBuffer cache or accept a deletion path
        // from launch arguments. One app-owned model prepares it before loading.
        let directory = cacheRoot.appendingPathComponent("HLSProxyBuffer-UIQualification", isDirectory: true)
        let files = FileManager.default
        if files.fileExists(atPath: directory.path) {
            try files.removeItem(at: directory)
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
