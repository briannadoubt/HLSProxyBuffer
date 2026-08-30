import Foundation
import HLSCore
import XCTest
@testable import ProxyPlayerKit

final class ManifestCacheLoaderTests: XCTestCase {
    private let text = """
    #EXTM3U
    #EXT-X-TARGETDURATION:2
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXTINF:2,
    segment.m4s
    #EXT-X-ENDLIST
    """

    func testFreshCanonicalEntrySkipsNetworkAndKeepsRelativeBaseURL() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test:8443/path/vod.m3u8?version=2"))
        let cache = makeCache()
        await cache.put(Data(text.utf8), for: "manifest-\(url.absoluteString)", validation: .init(freshUntil: .distantFuture))
        let result = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
            XCTFail("Fresh validated bytes must not contact the origin")
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(result.originFetchCount, 0)
        XCTAssertEqual(result.cacheHitCount, 1)
        XCTAssertEqual(result.manifest.mediaPlaylist?.segments.first?.url.absoluteString,
                       "https://cache.example.test:8443/path/segment.m4s")
        XCTAssertEqual(result.cacheHitByteCount, text.utf8.count)
    }

    func testExpiredEntryRequiresValidationAndAccepts304() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        let key = "manifest-\(url.absoluteString)"
        await cache.put(Data(text.utf8), for: key, validation: .init(
            eTag: "\"version-1\"", lastModified: "Wed, 26 Aug 2026 00:00:00 GMT", freshUntil: .distantPast
        ))
        let result = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { eTag, modified in
            XCTAssertEqual(eTag, "\"version-1\"")
            XCTAssertEqual(modified, "Wed, 26 Aug 2026 00:00:00 GMT")
            return .notModified(validation: .init(maximumAge: 60))
        }
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.cacheHitCount, 1)
        XCTAssertEqual(result.originFetchCount, 1)
        XCTAssertEqual(result.originFetchByteCount, 0)
        let refreshed = await cache.entry(for: key)
        XCTAssertEqual(refreshed?.validation?.eTag, "\"version-1\"")
        XCTAssertEqual(refreshed?.isExpired, false)
    }

    func testOriginPortAndQueryRemainPartOfCacheIdentity() async throws {
        let cache = makeCache()
        let original = "https://cache.example.test:8443/vod.m3u8?version=1"
        await cache.put(Data(text.utf8), for: "manifest-\(original)", validation: .init(freshUntil: .distantFuture))
        let text = text
        for rawURL in [
            "https://cache.example.test:8444/vod.m3u8?version=1",
            "https://cache.example.test:8443/vod.m3u8?version=2",
        ] {
            let url = try XCTUnwrap(URL(string: rawURL))
            let result = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { eTag, modified in
                XCTAssertNil(eTag)
                XCTAssertNil(modified)
                return .modified(text, validation: .init(maximumAge: 60))
            }
            XCTAssertEqual(result.originFetchCount, 1)
            XCTAssertEqual(result.cacheHitCount, 0)
        }
    }

    func testInvalidOriginManifestDoesNotReplaceValidatedBytes() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        let key = "manifest-\(url.absoluteString)"
        await cache.put(Data(text.utf8), for: key, validation: .init(freshUntil: .distantPast))
        do {
            _ = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
                .modified("not an HLS playlist", validation: .init(maximumAge: 60))
            }
            XCTFail("Malformed origin content must fail parsing")
        } catch {
            let retained = await cache.entry(for: key, allowingExpired: true)
            XCTAssertEqual(retained?.data, Data(text.utf8))
            XCTAssertEqual(retained?.isExpired, true)
        }
    }

    func testExpiredBytesAreNotUsedWhenValidationFails() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        await cache.put(Data(text.utf8), for: "manifest-\(url.absoluteString)", validation: .init(freshUntil: .distantPast))
        do {
            _ = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expired content needs successful origin validation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testNoStoreOnModifiedOr304ResponseRemovesCachedBytes() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        let key = "manifest-\(url.absoluteString)"
        let text = text
        for modified in [true, false] {
            await cache.put(Data(text.utf8), for: key, validation: .init(freshUntil: .distantPast))
            let result = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
                modified ? .modified(text, validation: .init(allowsStorage: false))
                    : .notModified(validation: .init(allowsStorage: false))
            }
            XCTAssertEqual(result.text, text)
            let retained = await cache.entry(for: key, allowingExpired: true)
            XCTAssertNil(retained)
        }
    }

    func test304WithoutCachedBytesIsRejected() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        do {
            _ = try await ManifestCacheLoader.load(from: url, cache: makeCache(), allowsInsecure: false) { _, _ in
                .notModified(validation: .init(maximumAge: 60))
            }
            XCTFail("A 304 is not a manifest without corresponding cached bytes")
        } catch HLSManifestFetcher.FetchError.invalidResponse {
            // Expected.
        }
    }

    func testMalformedNoStoreResponseStillRevokesCachedBytes() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        let key = "manifest-\(url.absoluteString)"
        await cache.put(Data(text.utf8), for: key, validation: .init(freshUntil: .distantPast))
        do {
            _ = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
                .modified("invalid", validation: .init(allowsStorage: false))
            }
            XCTFail("Malformed body must fail")
        } catch {
            let retained = await cache.entry(for: key, allowingExpired: true)
            XCTAssertNil(retained)
        }
    }

    func testCancelledTaskDoesNotReturnFreshCachedReadiness() async throws {
        let url = try XCTUnwrap(URL(string: "https://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        await cache.put(Data(text.utf8), for: "manifest-\(url.absoluteString)", validation: .init(freshUntil: .distantFuture))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
                XCTFail("Cancelled work must not fetch")
                throw URLError(.cancelled)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return readiness")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCacheReuseDoesNotBypassSourceTransportPolicy() async throws {
        let url = try XCTUnwrap(URL(string: "http://cache.example.test/vod.m3u8"))
        let cache = makeCache()
        await cache.put(Data(text.utf8), for: "manifest-\(url.absoluteString)")
        do {
            _ = try await ManifestCacheLoader.load(from: url, cache: cache, allowsInsecure: false) { _, _ in
                XCTFail("Transport must be rejected before fetching")
                throw URLError(.unsupportedURL)
            }
            XCTFail("Cached HTTP must not bypass HTTPS-only policy")
        } catch HLSManifestFetcher.FetchError.insecureScheme {
            // Expected.
        }
    }

    private func makeCache() -> HLSSegmentCache {
        HLSSegmentCache(capacityBytes: 16 * 1_024, diskCapacityBytes: 0)
    }
}
