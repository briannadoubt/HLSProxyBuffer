import Foundation
import HLSCore

/// Shared canonical manifest caching for predictive preparation and native
/// playback. Callers retain ownership of networking, retry and admission policy.
struct ManifestCacheLoader: Sendable {
    struct Result: Sendable {
        let text: String
        let manifest: HLSManifest
        let cacheHitCount: Int
        let originFetchCount: Int
        let cacheHitByteCount: Int
        let originFetchByteCount: Int
    }

    typealias Fetch = @Sendable (
        _ eTag: String?, _ lastModified: String?
    ) async throws -> HLSManifestFetcher.ValidatedManifest

    static func load(
        from url: URL,
        cache: HLSSegmentCache,
        allowsInsecure: Bool,
        fetch: Fetch
    ) async throws -> Result {
        try Task.checkCancellation()
        guard allowsInsecure || url.scheme?.lowercased() == "https" else {
            throw HLSManifestFetcher.FetchError.insecureScheme
        }
        // Keep the existing persistent key, including scheme, port and query.
        let key = "manifest-\(url.absoluteString)"
        let cached = await cache.entry(for: key, allowingExpired: true)
        try Task.checkCancellation()
        let parser = HLSParser()
        if let cached, !cached.isExpired,
           let text = String(data: cached.data, encoding: .utf8) {
            return Result(
                text: text, manifest: try parser.parse(text, baseURL: url),
                cacheHitCount: 1, originFetchCount: 0,
                cacheHitByteCount: cached.data.count, originFetchByteCount: 0
            )
        }

        let response = try await fetch(cached?.validation?.eTag, cached?.validation?.lastModified)
        try Task.checkCancellation()
        let text: String
        let data: Data
        let validation: HLSManifestFetcher.Validation
        let reused: Bool
        switch response {
        case .notModified(let value):
            guard let cached, let cachedText = String(data: cached.data, encoding: .utf8) else {
                throw HLSManifestFetcher.FetchError.invalidResponse(nil)
            }
            text = cachedText
            data = cached.data
            validation = value
            reused = true
        case .modified(let value, let originValidation):
            text = value
            data = Data(value.utf8)
            validation = originValidation
            reused = false
        }
        // Honor no-store even when the replacement body is malformed.
        if !validation.allowsStorage { await cache.remove(key) }
        // Invalid origin content must not poison a previously valid entry.
        let manifest = try parser.parse(text, baseURL: url)
        if validation.allowsStorage {
            let fallback = reused ? cached?.validation : nil
            await cache.put(data, for: key, validation: .init(
                eTag: validation.eTag ?? fallback?.eTag,
                lastModified: validation.lastModified ?? fallback?.lastModified,
                freshUntil: validation.maximumAge.map { Date().addingTimeInterval($0) }
            ))
        }
        try Task.checkCancellation()
        return Result(
            text: text, manifest: manifest,
            cacheHitCount: reused ? 1 : 0, originFetchCount: 1,
            cacheHitByteCount: reused ? data.count : 0,
            originFetchByteCount: reused ? 0 : data.count
        )
    }
}
