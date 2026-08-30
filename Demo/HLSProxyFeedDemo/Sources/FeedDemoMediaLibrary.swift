import CryptoKit
import Foundation
import HLSCore

/// Demo-only, checksum-bound real media. Loading retains metadata, never segment bodies.
struct FeedDemoMediaLibrary: Sendable {
    struct Catalog: Codable, Sendable {
        let schemaVersion: Int
        let corpusVersion: String
        let recipeSHA256: String
        let encoderVersion: String
        let probeVersion: String
        let encoding: String
        let sources: [Source]
        let clips: [Clip]
        let resources: [Resource]
    }

    struct Source: Codable, Sendable {
        let id: String
        let filename: String
        let title: String
        let author: String
        let credit: String
        let license: String
        let licenseURL: URL
        let rightsURL: URL
        let sourceURL: URL
        let downloadURL: URL
        let sha256: String
        let rightsNotes: String
    }

    struct Clip: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case liveAction, animation }
        let id: String
        let sourceID: String
        let startSeconds: Double
        let duration: Double
        let title: String
        let kind: Kind
        let audioContent: [String]
        let masterPath: String
        let renditions: [Rendition]
    }

    struct Rendition: Codable, Sendable {
        let id: String
        let playlistPath: String
        let initializationPath: String
        let width: Int
        let height: Int
        let videoCodec: String
        let audioCodec: String
        let frameRate: Int
        let audioSampleRate: Int
        let audioChannels: Int
        let audioLayout: String
        let videoRange: String
        let bandwidth: Int
        let averageBandwidth: Int
        let segmentDurations: [Double]
        let segmentPaths: [String]
        let analysis: Analysis
        let analysisResourceSHA256: [String: String]
    }

    struct Analysis: Codable, Sendable {
        let videoSampleCount: Int
        let lumaSHA256: [String]
        let distinctLumaSampleCount: Int
        let audioSampleCount: Int
        let audioRMSDBFS: Double
        let audioPeakDBFS: Double
        let videoDuration: Double
        let audioDuration: Double
        let maximumAVTimingDifference: Double
        let keyframeTimes: [Double]
    }

    struct Resource: Codable, Sendable {
        let path: String
        let byteCount: Int
        let sha256: String

        var contentType: String {
            switch (path as NSString).pathExtension {
            case "m3u8": "application/vnd.apple.mpegurl"
            case "mp4": "video/mp4"
            case "m4s": "video/iso.segment"
            default: "text/markdown; charset=utf-8"
            }
        }

        var etag: String { "\"sha256-\(sha256)\"" }
    }

    enum ValidationError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let reason): "Real demo media is invalid: \(reason)" }
        }
    }

    static let maximumBundleBytes = 50 * 1_024 * 1_024
    static let maximumResourceBytes = 1_024 * 1_024
    let rootURL: URL
    let catalog: Catalog
    let resourcesByPath: [String: Resource]
    let totalByteCount: Int

    var shortClips: [Clip] { catalog.clips.filter { $0.id != "continuous" } }
    var continuousClip: Clip? { catalog.clips.first { $0.id == "continuous" } }

    static func bundled() throws -> Self {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw ValidationError.invalid("missing Fixtures resource folder")
        }
        return try Self(rootURL: fixtures.appendingPathComponent("real"))
    }

    init(rootURL: URL) throws {
        self.rootURL = rootURL.resolvingSymlinksInPath()
        let catalogURL = self.rootURL.appendingPathComponent("catalog.json")
        let size = try catalogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try Self.check(size > 0 && size <= Self.maximumResourceBytes, "catalog size")
        let data = try Data(contentsOf: catalogURL)
        catalog = try JSONDecoder().decode(Catalog.self, from: data)
        try Self.check(catalog.resources.count <= 1_024, "resource count")
        try Self.check(Set(catalog.resources.map(\.path)).count == catalog.resources.count, "duplicate resource path")
        resourcesByPath = Dictionary(uniqueKeysWithValues: catalog.resources.map { ($0.path, $0) })
        try Self.check(catalog.resources.allSatisfy { (1...Self.maximumResourceBytes).contains($0.byteCount) }, "resource size")
        totalByteCount = catalog.resources.reduce(data.count) { $0 + $1.byteCount }
        try Self.check(totalByteCount <= Self.maximumBundleBytes, "50 MiB bundle cap")
        try validateMetadata()
    }

    /// Resolve only catalogued regular files beneath the corpus root, including symlink checks.
    func resourceURL(for path: String) throws -> URL {
        try Self.check(resourcesByPath[path] != nil && Self.isSafePath(path), "unrecognized resource path")
        let url = rootURL.appendingPathComponent(path).resolvingSymlinksInPath()
        try Self.check(url.path.hasPrefix(rootURL.path + "/"), "resource escapes corpus")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        try Self.check(values.isRegularFile == true && values.fileSize == resourcesByPath[path]?.byteCount, "missing or resized resource: \(path)")
        return url
    }

    /// Explicit CI/import audit. Streams one file at a time; not a launch-time corpus preload.
    func validateIntegrity() throws {
        for resource in catalog.resources {
            let handle = try FileHandle(forReadingFrom: resourceURL(for: resource.path))
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty { hash.update(data: data) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try Self.check(actual == resource.sha256, "checksum mismatch: \(resource.path)")
        }
        let inventory = catalog.resources.map {
            ["path": $0.path, "byteCount": $0.byteCount, "sha256": $0.sha256] as [String: Any]
        }
        let inventoryData = try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
        let inventoryHash = SHA256.hash(data: inventoryData).map { String(format: "%02x", $0) }.joined()
        try Self.check(catalog.corpusVersion == "real-v1-\(inventoryHash.prefix(12))", "corpus version does not bind output bytes")
        // FFmpeg's analysis is bound to exactly the resources decoded, not merely a clip ID.
        for clip in catalog.clips {
            for rendition in clip.renditions {
                let paths = [rendition.playlistPath, rendition.initializationPath] + rendition.segmentPaths
                try Self.check(Set(rendition.analysisResourceSHA256.keys) == Set(paths), "analysis inventory mismatch")
                for path in paths {
                    try Self.check(rendition.analysisResourceSHA256[path] == resourcesByPath[path]?.sha256, "stale analysis: \(path)")
                }
            }
        }
        let notices = try String(contentsOf: resourceURL(for: "NOTICES.md"), encoding: .utf8)
        try Self.check(notices.contains("Blender Foundation") && notices.contains("Janus Bager Kristensen") && notices.contains("NASA does not endorse"), "required attribution missing")
    }

    private func validateMetadata() throws {
        try Self.check(catalog.schemaVersion == 1 && catalog.corpusVersion.hasPrefix("real-v1-"), "unsupported catalog version")
        try Self.check(Self.isSafePath(catalog.corpusVersion) && !catalog.corpusVersion.contains("/"), "unsafe corpus version")
        try Self.check(Self.isSHA256(catalog.recipeSHA256) && !catalog.encoderVersion.isEmpty && !catalog.encoding.isEmpty, "missing generation provenance")
        try Self.check(catalog.clips.count == 25 && shortClips.count == 24 && continuousClip?.duration == 32, "clip count/duration")
        try Self.check(Set(catalog.clips.map(\.id)).count == 25, "duplicate clip identity")
        try Self.check(shortClips.allSatisfy { (8...15).contains($0.duration) }, "short clip duration")
        try Self.check(catalog.clips.reduce(0) { $0 + $1.duration } <= 240, "timeline cap")
        try Self.check(catalog.clips.contains { $0.kind == .liveAction }, "live-action coverage missing")
        try Self.check(Set(catalog.clips.flatMap(\.audioContent)).isSuperset(of: ["speech", "music", "effects"]), "audio coverage missing")
        let intervals = catalog.clips.map { "\($0.sourceID):\($0.startSeconds):\($0.duration)" }
        try Self.check(Set(intervals).count == 25, "duplicate source interval")
        try Self.check(Set(catalog.sources.map(\.id)).count == catalog.sources.count, "duplicate source")
        for source in catalog.sources {
            try Self.check(!source.credit.isEmpty && !source.author.isEmpty && !source.license.isEmpty && !source.rightsNotes.isEmpty && Self.isSHA256(source.sha256), "incomplete source provenance")
            try Self.check([source.sourceURL, source.downloadURL, source.licenseURL, source.rightsURL].allSatisfy { $0.scheme == "https" && $0.host != nil }, "invalid provenance URL")
        }
        for resource in catalog.resources {
            try Self.check(Self.isSHA256(resource.sha256), "invalid resource digest")
            _ = try resourceURL(for: resource.path)
        }
        for clip in catalog.clips {
            try Self.check(catalog.sources.contains { $0.id == clip.sourceID }, "unknown source")
            try Self.check(clip.startSeconds.isFinite && clip.startSeconds >= 0 && !clip.title.isEmpty, "invalid clip metadata")
            try Self.check(Set(clip.renditions.map(\.id)) == ["360p", "720p"] && clip.renditions.count == 2, "rendition coverage")
            try validatePlaylists(for: clip)
            for rendition in clip.renditions {
                try Self.check(rendition.width == (rendition.id == "360p" ? 640 : 1280) && rendition.height == (rendition.id == "360p" ? 360 : 720), "rendition geometry")
                try Self.check(rendition.videoCodec == "avc1.64001f" && rendition.audioCodec == "mp4a.40.2" && rendition.frameRate == 24, "measured codec/timing contract")
                try Self.check(rendition.audioSampleRate == 48_000 && rendition.audioChannels == 2 && rendition.audioLayout == "stereo" && rendition.videoRange == "SDR", "track layout")
                try Self.check(rendition.bandwidth > 0 && rendition.averageBandwidth > 0, "bandwidth")
                let analysis = rendition.analysis
                try Self.check(analysis.videoSampleCount == 8 && analysis.lumaSHA256.count == 8 && analysis.lumaSHA256.allSatisfy(Self.isSHA256), "video analysis")
                try Self.check(Set(analysis.lumaSHA256).count == analysis.distinctLumaSampleCount && analysis.distinctLumaSampleCount >= 4, "motion analysis")
                try Self.check(analysis.audioSampleCount > 0 && analysis.audioRMSDBFS > -60 && analysis.audioPeakDBFS > -40, "audio analysis")
                try Self.check(analysis.maximumAVTimingDifference <= 0.1 && analysis.maximumAVTimingDifference >= 0 && abs(analysis.videoDuration - clip.duration) < 0.05 && abs(analysis.audioDuration - clip.duration) <= 0.1, "A/V timing analysis")
                try Self.check(analysis.keyframeTimes.count == rendition.segmentPaths.count, "independence analysis")
                for (index, time) in analysis.keyframeTimes.enumerated() {
                    try Self.check(abs(time - Double(index * 2)) < 0.001, "keyframe alignment")
                }
            }
        }
    }

    private func validatePlaylists(for clip: Clip) throws {
        let parser = HLSParser()
        let masterURL = try resourceURL(for: clip.masterPath)
        let master = try parser.parse(String(contentsOf: masterURL, encoding: .utf8), baseURL: masterURL)
        try Self.check(master.kind == .master && master.variants.count == clip.renditions.count && master.independentSegments && master.protocolVersion == 7, "master playlist")
        for rendition in clip.renditions {
            let playlistURL = try resourceURL(for: rendition.playlistPath)
            guard let variant = master.variants.first(where: { $0.url == playlistURL }) else {
                throw ValidationError.invalid("missing master variant")
            }
            try Self.check(variant.attributes.bandwidth == rendition.bandwidth && variant.attributes.averageBandwidth == rendition.averageBandwidth && variant.attributes.codecs == "\(rendition.videoCodec),\(rendition.audioCodec)", "master metadata mismatch")
            try Self.check(variant.attributes.resolution?.width == rendition.width && variant.attributes.resolution?.height == rendition.height && variant.attributes.frameRate == Double(rendition.frameRate), "master geometry mismatch")
            let parsed = try parser.parse(String(contentsOf: playlistURL, encoding: .utf8), baseURL: playlistURL)
            guard let media = parsed.mediaPlaylist else { throw ValidationError.invalid("missing media playlist") }
            try Self.check(media.isEndlist && media.independentSegments && media.playlistType == "VOD" && media.mediaSequence == 0 && media.targetDuration == 2, "canonical VOD playlist contract")
            try Self.check(media.segments.count == rendition.segmentPaths.count && rendition.segmentPaths.count == rendition.segmentDurations.count, "media segment count")
            try Self.check(abs(media.segments.reduce(0) { $0 + $1.duration } - clip.duration) < 0.001, "playlist duration")
            let initializationURL = try resourceURL(for: rendition.initializationPath)
            for (index, segment) in media.segments.enumerated() {
                try Self.check(segment.encryption == nil && segment.byteRange == nil, "unsupported fixture segment")
                try Self.check(segment.url == resourceURL(for: rendition.segmentPaths[index]) && segment.initializationMap?.uri == initializationURL, "media reference mismatch")
                try Self.check(abs(segment.duration - 2) < 0.001 && segment.duration == rendition.segmentDurations[index], "segment duration/alignment")
                let bytes = resourcesByPath[rendition.segmentPaths[index]]?.byteCount ?? 0
                try Self.check(Double(bytes) * 8 / segment.duration <= Double(rendition.bandwidth), "understated bandwidth")
            }
        }
    }

    private static func check(_ valid: Bool, _ message: String) throws {
        guard valid else { throw ValidationError.invalid(message) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    private static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        }
    }
}
