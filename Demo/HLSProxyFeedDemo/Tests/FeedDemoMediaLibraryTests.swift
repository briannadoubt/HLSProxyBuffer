import CryptoKit
import Foundation
import XCTest
@testable import HLSProxyFeedDemo

final class FeedDemoMediaLibraryTests: XCTestCase {
    func testBundledCorpusMeetsSizeProvenanceAndDecodeContracts() throws {
        let library = try FeedDemoMediaLibrary.bundled()
        try library.validateIntegrity()
        XCTAssertEqual(library.shortClips.count, 24)
        XCTAssertEqual(library.catalog.clips.count, 25)
        XCTAssertEqual(library.continuousClip?.duration, 32)
        XCTAssertEqual(library.catalog.clips.reduce(0) { $0 + $1.duration }, 224)
        XCTAssertLessThanOrEqual(library.totalByteCount, 50 * 1_024 * 1_024)
        XCTAssertTrue(library.catalog.resources.allSatisfy { $0.byteCount <= 1_024 * 1_024 })
        XCTAssertEqual(library.catalog.clips.flatMap(\.renditions).count, 50)
        XCTAssertEqual(library.shortClips.filter { $0.kind == .liveAction }.count, 8)

        for rendition in library.catalog.clips.flatMap(\.renditions) {
            XCTAssertEqual(rendition.analysis.videoSampleCount, 8)
            XCTAssertGreaterThanOrEqual(rendition.analysis.distinctLumaSampleCount, 4)
            XCTAssertGreaterThan(rendition.analysis.audioRMSDBFS, -60)
            XCTAssertGreaterThan(rendition.analysis.audioPeakDBFS, -40)
            XCTAssertLessThanOrEqual(rendition.analysis.maximumAVTimingDifference, 0.1)
            XCTAssertEqual(rendition.audioChannels, 2)
        }
        // A new namespace alone must not disguise reused synthetic media.
        for renditionIndex in 0...1 {
            let mediaHashes = library.shortClips.map { clip in
                clip.renditions[renditionIndex].segmentPaths.compactMap { library.resourcesByPath[$0]?.sha256 }.joined()
            }
            XCTAssertEqual(Set(mediaHashes).count, 24)
        }
    }

    func testRecipeAndNoticesMatchTheirPackagedProvenance() throws {
        let library = try FeedDemoMediaLibrary.bundled()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent("Scripts/real-feed-media-source.json").path) else {
            throw XCTSkip("Maintainer recipe comparison requires the source checkout; bundled integrity runs on all platforms")
        }
        let recipe = try Data(contentsOf: repository.appendingPathComponent("Scripts/real-feed-media-source.json"))
        let hash = SHA256.hash(data: recipe).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, library.catalog.recipeSHA256)
        XCTAssertEqual(
            try Data(contentsOf: repository.appendingPathComponent("Scripts/real-feed-media-notices.md")),
            try Data(contentsOf: library.resourceURL(for: "NOTICES.md"))
        )
        let recipeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: recipe) as? [String: Any])
        let sourceData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(recipeObject["sources"]))
        let sources = try JSONDecoder().decode([FeedDemoMediaLibrary.Source].self, from: sourceData)
        XCTAssertEqual(sources.map(\.sha256), library.catalog.sources.map(\.sha256))
    }

    func testMissingAndUnsafeResourcesFailWithoutSyntheticFallback() throws {
        let library = try FeedDemoMediaLibrary.bundled()
        for path in ["../short-a/init.mp4", "/etc/passwd", "feed-01/%2e%2e/init.mp4", "feed-01//init.mp4", "unlisted.m4s"] {
            XCTAssertThrowsError(try library.resourceURL(for: path), path)
        }
        try withTemporaryCopy { root in
            let path = try XCTUnwrap(library.shortClips.first?.renditions.first?.segmentPaths.first)
            try FileManager.default.removeItem(at: root.appendingPathComponent(path))
            XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root))
        }
    }

    func testSameLengthCorruptionIsDetectedByStreamingIntegrityAudit() throws {
        try withTemporaryCopy { root in
            let original = try FeedDemoMediaLibrary(rootURL: root)
            let path = try XCTUnwrap(original.shortClips.first?.renditions.first?.segmentPaths.first)
            let url = root.appendingPathComponent(path)
            var data = try Data(contentsOf: url)
            data[data.startIndex] ^= 0xff
            try data.write(to: url, options: .atomic)
            let metadataOnly = try FeedDemoMediaLibrary(rootURL: root)
            XCTAssertThrowsError(try metadataOnly.validateIntegrity())
        }
    }

    func testPlaylistCannotSilentlyChangeFromVODToLive() throws {
        try withTemporaryCopy { root in
            let original = try FeedDemoMediaLibrary(rootURL: root)
            let path = try XCTUnwrap(original.shortClips.first?.renditions.first?.playlistPath)
            let url = root.appendingPathComponent(path)
            let tag = "#EXT-X-ENDLIST"
            let text = try String(contentsOf: url, encoding: .utf8)
            try text.replacingOccurrences(of: tag, with: String(repeating: "#", count: tag.count))
                .write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root))
        }
    }

    func testStaleAnalysisAndUnversionedReplacementAreRejected() throws {
        try withTemporaryCopy { root in
            try mutateCatalog(at: root) { json in
                var clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
                var renditions = try XCTUnwrap(clips[0]["renditions"] as? [[String: Any]])
                var binding = try XCTUnwrap(renditions[0]["analysisResourceSHA256"] as? [String: String])
                let path = try XCTUnwrap(binding.keys.sorted().first)
                binding[path] = String(repeating: "0", count: 64)
                renditions[0]["analysisResourceSHA256"] = binding
                clips[0]["renditions"] = renditions
                json["clips"] = clips
            }
            XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root).validateIntegrity())
        }
        try withTemporaryCopy { root in
            try mutateCatalog(at: root) { $0["corpusVersion"] = "real-v1-000000000000" }
            XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root).validateIntegrity())
        }
    }

    func testDuplicateResourcesAndOversizeMetadataFailClosed() throws {
        try withTemporaryCopy { root in
            try mutateCatalog(at: root) { json in
                var resources = try XCTUnwrap(json["resources"] as? [[String: Any]])
                resources.append(try XCTUnwrap(resources.first))
                json["resources"] = resources
            }
            XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root))
        }
        try withTemporaryCopy { root in
            try mutateCatalog(at: root) { json in
                var resources = try XCTUnwrap(json["resources"] as? [[String: Any]])
                resources[0]["byteCount"] = Int.max
                json["resources"] = resources
            }
            XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root))
        }
    }

    func testInvalidTrackLayoutAndSilentOrStaticAnalysisAreRejected() throws {
        for field in ["audioChannels", "audioRMSDBFS", "lumaSHA256", "maximumAVTimingDifference"] {
            try withTemporaryCopy { root in
                try mutateCatalog(at: root) { json in
                    var clips = try XCTUnwrap(json["clips"] as? [[String: Any]])
                    var renditions = try XCTUnwrap(clips[0]["renditions"] as? [[String: Any]])
                    if field == "audioChannels" {
                        renditions[0][field] = 1
                    } else {
                        var analysis = try XCTUnwrap(renditions[0]["analysis"] as? [String: Any])
                        switch field {
                        case "audioRMSDBFS": analysis[field] = -80
                        case "lumaSHA256":
                            analysis[field] = Array(repeating: String(repeating: "0", count: 64), count: 8)
                            analysis["distinctLumaSampleCount"] = 1
                        default: analysis[field] = 0.5
                        }
                        renditions[0]["analysis"] = analysis
                    }
                    clips[0]["renditions"] = renditions
                    json["clips"] = clips
                }
                XCTAssertThrowsError(try FeedDemoMediaLibrary(rootURL: root), field)
            }
        }
    }

    func testSyntheticOriginDoesNotExposeOrPreloadRealCorpus() async throws {
        let origin = try FeedDemoFixtureOrigin()
        let baseURL = try await origin.start()
        defer { origin.stop() }
        let (_, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("real/feed-01/360p/segment-000.m4s"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    private func withTemporaryCopy(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hls-media-test-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: FeedDemoMediaLibrary.bundled().rootURL, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func mutateCatalog(at root: URL, _ change: (inout [String: Any]) throws -> Void) throws {
        let url = root.appendingPathComponent("catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try change(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}
