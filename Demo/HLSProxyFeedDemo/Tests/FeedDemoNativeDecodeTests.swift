import AVFoundation
import CryptoKit
import XCTest
@testable import HLSProxyFeedDemo

/// Independent native decode of exact packaged fragments, not the importer's asserted report.
@MainActor
final class FeedDemoNativeDecodeTests: XCTestCase {
    private struct DecodeEvidence: Codable {
        let clipKind: String
        let rendition: String
        let videoFrames: Int
        let sampledFrames: Int
        let distinctLumaSamples: Int
        let pcmSamples: Int
        let audioRMSDBFS: Double
        let audioPeakDBFS: Double
        let videoDuration: Double
        let audioDuration: Double
    }

    func testRepresentativeRealVideoAndPCMDecodeAtBothRenditions() async throws {
        let library = try FeedDemoMediaLibrary.bundled()
        try library.validateIntegrity()
        let clips = try [FeedDemoMediaLibrary.Clip.Kind.liveAction, .animation].map { kind in
            try XCTUnwrap(library.shortClips.first { $0.kind == kind })
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hls-native-decode-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var evidence: [DecodeEvidence] = []
        for clip in clips {
            for rendition in clip.renditions {
                let url = root.appendingPathComponent("\(clip.id)-\(rendition.id).mp4")
                // One bounded resource at a time; no alternate source media or remuxing.
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                do {
                    for path in [rendition.initializationPath] + rendition.segmentPaths {
                        try handle.write(contentsOf: Data(contentsOf: library.resourceURL(for: path)))
                    }
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                let asset = AVURLAsset(url: url)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let video = try XCTUnwrap(videoTracks.first)
                let audio = try XCTUnwrap(audioTracks.first)
                let size = try await video.load(.naturalSize)
                XCTAssertEqual(Int(size.width), rendition.width)
                XCTAssertEqual(Int(size.height), rendition.height)
                let formats = try await audio.load(.formatDescriptions)
                let format = try XCTUnwrap(formats.first)
                let description = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
                XCTAssertEqual(description.pointee.mChannelsPerFrame, 2)
                XCTAssertEqual(description.pointee.mSampleRate, 48_000)

                let frameDuration = try await video.load(.minFrameDuration)
                let videoResult = try decodeVideo(
                    asset: asset, track: video, duration: clip.duration, frameDuration: frameDuration
                )
                let audioResult = try decodeAudio(asset: asset, track: audio)
                let result = DecodeEvidence(
                    clipKind: clip.kind.rawValue, rendition: rendition.id,
                    videoFrames: videoResult.frames, sampledFrames: videoResult.signatures.count,
                    distinctLumaSamples: Set(videoResult.signatures).count,
                    pcmSamples: audioResult.samples, audioRMSDBFS: audioResult.rms,
                    audioPeakDBFS: audioResult.peak, videoDuration: videoResult.duration,
                    audioDuration: audioResult.duration
                )
                evidence.append(result)
                // AVFoundation can synthesize an initial presentation sample at
                // time zero before the first encoded PTS (21ms in this corpus).
                // Validate decoded coverage/timing, not encoded packet count.
                XCTAssertGreaterThanOrEqual(result.videoFrames, Int(clip.duration * 24), rendition.id)
                XCTAssertEqual(result.sampledFrames, 8)
                XCTAssertGreaterThanOrEqual(result.distinctLumaSamples, 4)
                XCTAssertGreaterThan(result.pcmSamples, 0)
                XCTAssertGreaterThan(result.audioRMSDBFS, -60)
                XCTAssertGreaterThan(result.audioPeakDBFS, -40)
                XCTAssertEqual(result.videoDuration, clip.duration, accuracy: 0.1)
                XCTAssertEqual(result.audioDuration, clip.duration, accuracy: 0.1)
                XCTAssertLessThanOrEqual(abs(result.videoDuration - result.audioDuration), 0.1)
            }
        }
        struct Report: Encodable {
            let schemaVersion = 1
            let qualificationKind = "real_audiovisual_native_decode"
            let corpusVersion: String
            let evidence: [DecodeEvidence]
        }
        let data = try JSONEncoder().encode(Report(corpusVersion: library.catalog.corpusVersion, evidence: evidence))
        XCTAssertLessThan(data.count, 8_192)
        if let path = ProcessInfo.processInfo.environment["HLS_CI_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("hls-real-native-decode.json"), options: .atomic)
        }
        print("HLS_NATIVE_DECODE \(String(decoding: data, as: UTF8.self))")
    }

    private func decodeVideo(
        asset: AVAsset, track: AVAssetTrack, duration: Double, frameDuration: CMTime
    ) throws -> (frames: Int, signatures: [String], duration: Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var frames = 0
        var signatures: [String] = []
        var firstTime: Double?
        var endTime = 0.0
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let sample = output.copyNextSampleBuffer() else { return false }
            guard ContinuousClock.now < deadline else { throw DecodeError.deadline }
            // Empty sample buffers are not decoded frames.
            guard sample.numSamples > 0 else { return true }
            let pixel = try XCTUnwrap(sample.imageBuffer)
            let time = sample.presentationTimeStamp.seconds
            firstTime = firstTime ?? time
            endTime = time + (sample.duration.isNumeric ? sample.duration : frameDuration).seconds
            frames += 1
            if signatures.count < 8, time - (firstTime ?? 0) >= Double(signatures.count) * duration / 8 {
                XCTAssertEqual(CVPixelBufferGetPlaneCount(pixel), 2)
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 0))
                let width = CVPixelBufferGetWidthOfPlane(pixel, 0)
                let height = CVPixelBufferGetHeightOfPlane(pixel, 0)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
                var hash = SHA256()
                // Ignore row padding; it is not image content and may be uninitialized.
                for row in 0..<height {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: row * stride), count: width))
                }
                signatures.append(hash.finalize().map { String(format: "%02x", $0) }.joined())
            }
            return true
        }) {}
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return (frames, signatures, endTime - (firstTime ?? 0))
    }

    private func decodeAudio(
        asset: AVAsset, track: AVAssetTrack
    ) throws -> (samples: Int, rms: Double, peak: Double, duration: Double) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var samples = 0
        var sumSquares = 0.0
        var peak = 0.0
        var firstTime: Double?
        var endTime = 0.0
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let sample = output.copyNextSampleBuffer() else { return false }
            guard ContinuousClock.now < deadline else { throw DecodeError.deadline }
            firstTime = firstTime ?? sample.presentationTimeStamp.seconds
            endTime = sample.presentationTimeStamp.seconds + sample.duration.seconds
            let block = try XCTUnwrap(sample.dataBuffer)
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length % MemoryLayout<Float>.size == 0, length <= 1_024 * 1_024 else {
                throw DecodeError.invalidPCM
            }
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = try values.withUnsafeMutableBytes {
                let base = try XCTUnwrap($0.baseAddress)
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { throw DecodeError.invalidPCM }
            for value in values {
                guard value.isFinite else { throw DecodeError.invalidPCM }
                let value = Double(value)
                sumSquares += value * value
                peak = max(peak, abs(value))
            }
            samples += values.count
            return true
        }) {}
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return (samples, 10 * log10(max(sumSquares / Double(max(1, samples)), 1e-16)),
                20 * log10(max(peak, 1e-8)), endTime - (firstTime ?? 0))
    }

    private enum DecodeError: Error { case deadline, invalidPCM }
}
