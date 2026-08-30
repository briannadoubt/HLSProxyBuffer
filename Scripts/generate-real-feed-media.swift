#!/usr/bin/env swift
// Maintainer-only importer. CI consumes the committed, checksum-bound outputs.
import CryptoKit
import Foundation

enum ImportError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): message } }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ImportError.invalid(message) }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fileDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + arguments
    let output = Pipe()
    process.standardOutput = output
    // Inherit stderr: a separate unread pipe can deadlock a failed encoder.
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "\(tool) failed (\(process.terminationStatus))")
    return data
}

func object(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ImportError.invalid("Expected a JSON object")
    }
    return result
}

func number(_ value: Any?) -> Double {
    if let string = value as? String { return Double(string) ?? .nan }
    return (value as? NSNumber)?.doubleValue ?? .nan
}

func probe(_ url: URL, packets: Bool = false) throws -> [String: Any] {
    try object(run("ffprobe", ["-v", "error", "-allowed_extensions", "ALL"]
        + (packets ? ["-show_packets", "-show_entries", "packet=stream_index,pts_time,duration_time,flags"] : ["-show_streams"])
        + ["-of", "json", url.path]))
}

func resources(in root: URL) throws -> [[String: Any]] {
    let manager = FileManager.default
    let root = root.resolvingSymlinksInPath()
    guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw ImportError.invalid("Cannot enumerate staged output")
    }
    var result: [[String: Any]] = []
    for case let url as URL in enumerator {
        let url = url.resolvingSymlinksInPath()
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        try require(url.path.hasPrefix(root.path + "/"), "Resource escapes staging")
        let path = String(url.path.dropFirst(root.path.count + 1))
        let size = try manager.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        try require(size > 0 && size <= 1_048_576, "Resource exceeds 1 MiB or is empty: \(path)")
        result.append(["path": path, "byteCount": size, "sha256": try fileDigest(url)])
    }
    return result.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
}

func analyze(_ playlist: URL, duration: Double) throws -> [String: Any] {
    let input = ["-v", "error", "-xerror", "-allowed_extensions", "ALL", "-i", playlist.path]
    // Decode the complete video, then sample eight regularly spaced luma frames.
    let video = try run("ffmpeg", input + ["-map", "0:v:0", "-vf", "fps=8/\(duration),scale=16:16", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"])
    try require(video.count == 8 * 256, "Expected eight decoded luma samples: \(playlist.path)")
    let signatures = stride(from: 0, to: video.count, by: 256).map { digest(video.subdata(in: $0..<($0 + 256))) }
    try require(Set(signatures).count >= 4, "Insufficient visible motion: \(playlist.path)")
    let firstFrame = video.prefix(256)
    try require(firstFrame.reduce(0) { $0 + Int($1) } > 256 * 2, "Black opening: \(playlist.path)")

    let audio = try run("ffmpeg", input + ["-map", "0:a:0", "-vn", "-ac", "2", "-ar", "48000", "-f", "f32le", "pipe:1"])
    try require(!audio.isEmpty && audio.count.isMultiple(of: 4), "No decoded audio: \(playlist.path)")
    var sum = 0.0
    var peak = 0.0
    audio.withUnsafeBytes { bytes in
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            let value = Double(Float(bitPattern: bits))
            sum += value * value
            peak = max(peak, abs(value))
        }
    }
    let sampleCount = audio.count / 4
    let rmsDBFS = 10 * log10(sum / Double(sampleCount))
    let peakDBFS = 20 * log10(peak)
    try require(rmsDBFS.isFinite && rmsDBFS > -60 && peakDBFS > -40, "Silent audio: \(playlist.path)")

    let packets = try probe(playlist, packets: true)["packets"] as? [[String: Any]] ?? []
    func timing(_ index: Int) throws -> (start: Double, end: Double, duration: Double) {
        let selected = packets.filter { ($0["stream_index"] as? Int) == index }
        let start = selected.map { number($0["pts_time"]) }.min() ?? .nan
        let end = selected.map { number($0["pts_time"]) + number($0["duration_time"]) }.max() ?? .nan
        try require(start.isFinite && end.isFinite && end > start, "Invalid decoded packet timing")
        return (start, end, end - start)
    }
    let videoTiming = try timing(0)
    let audioTiming = try timing(1)
    let mismatch = max(abs(videoTiming.duration - audioTiming.duration), abs(videoTiming.end - audioTiming.end), abs(videoTiming.start - audioTiming.start))
    try require(mismatch <= 0.1, "A/V timing mismatch exceeds 100 ms: \(mismatch)")
    try require(abs(videoTiming.duration - duration) < 0.05, "Unexpected video duration")
    let keyframes = packets.filter { ($0["stream_index"] as? Int) == 0 && ($0["flags"] as? String ?? "").contains("K") }
        .map { number($0["pts_time"]) - videoTiming.start }
    try require(keyframes.count == Int(duration / 2), "Unexpected independent segment count")
    for (index, time) in keyframes.enumerated() {
        try require(abs(time - Double(index * 2)) < 0.001, "Unaligned keyframe")
    }
    return [
        "videoSampleCount": 8, "lumaSHA256": signatures,
        "distinctLumaSampleCount": Set(signatures).count,
        "audioSampleCount": sampleCount, "audioRMSDBFS": rmsDBFS, "audioPeakDBFS": peakDBFS,
        "videoDuration": videoTiming.duration, "audioDuration": audioTiming.duration,
        "maximumAVTimingDifference": mismatch, "keyframeTimes": keyframes,
    ]
}

func generate() throws {
    try require((2...3).contains(CommandLine.arguments.count), "Usage: swift Scripts/generate-real-feed-media.swift /absolute/source-cache [--verify]")
    let verifyOnly = CommandLine.arguments.count == 3
    try require(!verifyOnly || CommandLine.arguments[2] == "--verify", "Unknown importer option")
    let manager = FileManager.default
    let root = URL(fileURLWithPath: manager.currentDirectoryPath).standardizedFileURL
    let cache = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    try require(CommandLine.arguments[1].hasPrefix("/") && !cache.path.hasPrefix(root.path + "/") && cache != root, "Source cache must be outside the repository")
    let recipeURL = root.appendingPathComponent("Scripts/real-feed-media-source.json")
    let recipeData = try Data(contentsOf: recipeURL)
    let recipe = try object(recipeData)
    let sources = recipe["sources"] as? [[String: Any]] ?? []
    let clips = recipe["clips"] as? [[String: Any]] ?? []
    try require(clips.count == 25 && Set(clips.compactMap { $0["id"] as? String }).count == 25, "Expected 25 distinct clip identities")
    try require(clips.reduce(0) { $0 + number($1["duration"]) } <= 240, "Timeline exceeds 240 s")
    try require(clips.filter { ($0["id"] as? String) != "continuous" }.allSatisfy { (8...15).contains(number($0["duration"])) }, "Short clip must be 8–15 s")
    try require(clips.first { ($0["id"] as? String) == "continuous" }.map { number($0["duration"]) == 32 } == true, "Expected 32 s continuous cut")
    for source in sources {
        guard let filename = source["filename"] as? String, let expected = source["sha256"] as? String else { throw ImportError.invalid("Invalid source") }
        try require(!filename.contains("/") && filename != "..", "Unsafe source filename")
        let actual = try fileDigest(cache.appendingPathComponent(filename))
        try require(actual == expected, "Source checksum mismatch: \(filename)")
    }
    let version = String(decoding: try run("ffmpeg", ["-version"]), as: UTF8.self)
    let probeVersion = String(decoding: try run("ffprobe", ["-version"]), as: UTF8.self)
    try require(version.hasPrefix("ffmpeg version 8.1.1 ") && probeVersion.hasPrefix("ffprobe version 8.1.1 "), "Reviewed importer requires FFmpeg/FFprobe 8.1.1; explicitly review a toolchain change")

    let fixtures = root.appendingPathComponent("Demo/HLSProxyFeedDemo/Fixtures")
    let staging = manager.temporaryDirectory.appendingPathComponent("hls-real-import-\(UUID().uuidString)")
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    print("Staging: \(staging.path)")
    // Retain failed staging for diagnostics; never disturb the installed corpus on failure.
    var encodedClips: [[String: Any]] = []
    for clip in clips {
        guard let id = clip["id"] as? String, let sourceID = clip["sourceID"] as? String,
              let source = sources.first(where: { ($0["id"] as? String) == sourceID }),
              let filename = source["filename"] as? String else { throw ImportError.invalid("Invalid clip source") }
        try require(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, "Unsafe clip ID")
        let duration = number(clip["duration"])
        var renditions: [[String: Any]] = []
        for (height, width, bitrate) in [(360, 640, 320_000), (720, 1280, 1_000_000)] {
            let relative = "\(id)/\(height)p"
            let folder = staging.appendingPathComponent(relative)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let playlist = folder.appendingPathComponent("playlist.m3u8")
            let arguments = [
                "-v", "error", "-xerror", "-threads", "1", "-filter_threads", "1",
                "-ss", String(number(clip["startSeconds"])), "-i", cache.appendingPathComponent(filename).path,
                "-t", String(duration), "-map", "0:v:0", "-map", "0:a:0",
                "-vf", "fps=24,scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1",
                "-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-level:v", "3.1", "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
                "-b:v", String(bitrate), "-maxrate", String(bitrate * 5 / 4), "-bufsize", String(bitrate * 2),
                "-g", "48", "-keyint_min", "48", "-sc_threshold", "0", "-bf", "0", "-threads", "1",
                "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact",
                "-c:a", "aac", "-b:a", "96k", "-ar", "48000", "-ac", "2", "-map_metadata", "-1",
                "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_flags", "independent_segments",
                "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
                "-hls_segment_filename", folder.appendingPathComponent("segment-%03d.m4s").path, playlist.path,
            ]
            try run("ffmpeg", arguments)
            let streams = try probe(playlist)["streams"] as? [[String: Any]] ?? []
            guard let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }),
                  let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" }),
                  let videoCodec = video["mime_codec_string"] as? String,
                  let audioCodec = audio["mime_codec_string"] as? String else { throw ImportError.invalid("Missing measured tracks") }
            try require(video["codec_name"] as? String == "h264" && audio["codec_name"] as? String == "aac" && audio["profile"] as? String == "LC", "Unexpected codecs")
            try require(video["width"] as? Int == width && video["height"] as? Int == height && video["avg_frame_rate"] as? String == "24/1", "Unexpected video geometry/timing")
            try require(audio["channels"] as? Int == 2 && audio["sample_rate"] as? String == "48000" && audio["channel_layout"] as? String == "stereo", "Unexpected audio layout")
            let text = try String(contentsOf: playlist, encoding: .utf8)
            let durations = text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).split(separator: ",")[0]) }
            try require(durations.count == Int(duration / 2) && durations.allSatisfy { abs($0 - 2) < 0.001 }, "Unexpected segment boundaries")
            let inventory = try resources(in: folder)
            let segments = inventory.filter { ($0["path"] as? String ?? "").hasSuffix(".m4s") }
            let peakBits = segments.map { Double($0["byteCount"] as? Int ?? 0) * 8 / 2 }.max() ?? 0
            let segmentBytes = segments.reduce(0) { $0 + ($1["byteCount"] as? Int ?? 0) }
            let analysis = try analyze(playlist, duration: duration)
            renditions.append([
                "id": "\(height)p", "playlistPath": "\(relative)/playlist.m3u8", "initializationPath": "\(relative)/init.mp4",
                "width": video["width"] ?? width, "height": video["height"] ?? height,
                "videoCodec": videoCodec, "audioCodec": audioCodec, "frameRate": 24,
                "audioSampleRate": 48000, "audioChannels": 2, "audioLayout": "stereo", "videoRange": "SDR",
                "bandwidth": Int(ceil(peakBits * 1.1)), "averageBandwidth": Int(ceil(Double(segmentBytes) * 8 / duration)),
                "segmentDurations": durations, "segmentPaths": segments.compactMap { ($0["path"] as? String).map { "\(relative)/\($0)" } },
                "analysis": analysis,
                "analysisResourceSHA256": Dictionary(uniqueKeysWithValues: inventory.map { ("\(relative)/\($0["path"] as? String ?? "")", $0["sha256"] as? String ?? "") }),
            ])
            print("Validated \(id) \(height)p: \(segmentBytes) bytes")
        }
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        for variant in renditions {
            guard let bandwidth = variant["bandwidth"] as? Int,
                  let averageBandwidth = variant["averageBandwidth"] as? Int,
                  let width = variant["width"] as? Int, let height = variant["height"] as? Int,
                  let videoCodec = variant["videoCodec"] as? String, let audioCodec = variant["audioCodec"] as? String,
                  let id = variant["id"] as? String else { throw ImportError.invalid("Incomplete measured variant") }
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(averageBandwidth),RESOLUTION=\(width)x\(height),FRAME-RATE=24.000,CODECS=\"\(videoCodec),\(audioCodec)\",VIDEO-RANGE=SDR\n\(id)/playlist.m3u8\n"
        }
        try master.write(to: staging.appendingPathComponent("\(id)/master.m3u8"), atomically: true, encoding: .utf8)
        var encoded = clip
        encoded["masterPath"] = "\(id)/master.m3u8"
        encoded["renditions"] = renditions
        encodedClips.append(encoded)
    }
    try manager.copyItem(at: root.appendingPathComponent("Scripts/real-feed-media-notices.md"), to: staging.appendingPathComponent("NOTICES.md"))
    let inventory = try resources(in: staging)
    let inventoryJSON = try JSONSerialization.data(withJSONObject: inventory, options: [.sortedKeys])
    let corpusVersion = "\(recipe["revision"] as? String ?? "real-v1")-\(digest(inventoryJSON).prefix(12))"
    let catalog: [String: Any] = [
        "schemaVersion": 1, "corpusVersion": corpusVersion, "recipeSHA256": digest(recipeData),
        "encoderVersion": version, "probeVersion": probeVersion,
        "encoding": "libx264 medium High 3.1 yuv420p BT.709 SDR; 24fps; fit+pad; 360p 320k/400k max, 720p 1000k/1250k max; VBV 2x; closed GOP48, no B-frames/scenecut; single-thread decoder/filter/encoder, bitexact flags; AAC-LC 48kHz stereo 96k; fMP4 HLS 2s VOD independent segments",
        "sources": sources, "clips": encodedClips, "resources": inventory,
    ]
    let catalogData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try require(catalogData.count <= 1_048_576, "Catalog exceeds 1 MiB metadata cap")
    let totalBytes = inventory.reduce(catalogData.count) { $0 + ($1["byteCount"] as? Int ?? 0) }
    try require(totalBytes <= 50 * 1_048_576, "Corpus exceeds 50 MiB: \(totalBytes)")
    try catalogData.write(to: staging.appendingPathComponent("catalog.json"), options: .atomic)
    let destination = fixtures.appendingPathComponent("real")
    if verifyOnly {
        let installed = try Data(contentsOf: destination.appendingPathComponent("catalog.json"))
        try require(installed == catalogData, "Regeneration differs from installed corpus; staged files retained for review")
        for resource in inventory {
            guard let path = resource["path"] as? String, let expected = resource["sha256"] as? String else {
                throw ImportError.invalid("Invalid regenerated resource")
            }
            let actual = try fileDigest(destination.appendingPathComponent(path))
            try require(actual == expected, "Installed bytes differ: \(path)")
        }
        print("Verified byte-identical catalog and every resource digest: \(corpusVersion)")
        return
    }
    let backup = manager.temporaryDirectory.appendingPathComponent("hls-real-backup-\(UUID().uuidString)")
    if manager.fileExists(atPath: destination.path) {
        try manager.moveItem(at: destination, to: backup)
        print("Previous corpus preserved: \(backup.path)")
    }
    do { try manager.moveItem(at: staging, to: destination) }
    catch {
        if manager.fileExists(atPath: backup.path) { try? manager.moveItem(at: backup, to: destination) }
        throw error
    }
    print("Installed \(corpusVersion): \(totalBytes) bytes, 25 clips, 50 decoded renditions")
}

do { try generate() }
catch { FileHandle.standardError.write(Data("Import failed: \(error)\n".utf8)); exit(1) }
