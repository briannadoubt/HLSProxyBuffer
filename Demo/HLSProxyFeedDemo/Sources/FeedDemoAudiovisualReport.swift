import Foundation
import ProxyPlayerKit

/// Bounded UI-side evidence. The CI compositor joins this with independently
/// decoded PCM/video evidence for the same corpus, never with source audio.
struct FeedDemoAudiovisualReport: Codable, Equatable, Sendable {
    struct VideoPath: Codable, Equatable, Sendable {
        let path: HLSFeedTelemetry.Path
        let decodedFirstFrameLatency: HLSFeedTelemetry.Distribution?
        let playbackStartStages: HLSFeedTelemetry.PlaybackStartStages?
        let sampledFrameCount: UInt64?
        let advancingFrameCount: UInt64?
    }

    let schemaVersion: Int
    let qualificationKind: String
    let corpusVersion: String?
    let passed: Bool
    let failureCodes: [String]
    let vertical: FeedDemoVerticalQualificationReport
    let videoPaths: [VideoPath]
    let nativeAudio: HLSFeedTelemetry.NativeAudioSnapshot?
    let originPayload: FeedDemoBodyBudget.Snapshot
    let originBodyLimit: Int
    let originPayloadByteLimit: Int
    let warmPlaybackStart: FeedDemoVerticalQualificationReport.Distribution
    let warmDecodedFirstFrame: FeedDemoVerticalQualificationReport.Distribution
    let coldDecodedFirstFrame: FeedDemoVerticalQualificationReport.Distribution
    let finalFramesAdvancing: Bool
    let timingProfile: FeedDemoQualificationTimingPolicy.Profile?
    let warmPlaybackP95LimitMilliseconds: Double?
    let warmDecodedP95LimitMilliseconds: Double?

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), data.count <= 64 * 1_024 else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func make(
        vertical: FeedDemoVerticalQualificationReport,
        engine: HLSFeedEngineSnapshot,
        telemetry: HLSFeedTelemetry.Snapshot,
        origin: FeedDemoFixtureOrigin.Snapshot,
        configuration: FeedDemoFixtureOrigin.Configuration,
        timingPolicy: FeedDemoQualificationTimingPolicy = .releaseReference
    ) -> Self {
        let warm = telemetry.paths.filter { $0.path.reuse == .warm && $0.path.intent == .focused }
        let cold = telemetry.paths.filter { $0.path.reuse == .cold && $0.path.intent == .focused }
        let warmPlayback = FeedDemoVerticalQualificationReport.summary(warm.map(\.firstFrameLatency))
        let warmDecoded = FeedDemoVerticalQualificationReport.summary(warm.compactMap(\.decodedFirstFrameLatency))
        let coldDecoded = FeedDemoVerticalQualificationReport.summary(cold.compactMap(\.decodedFirstFrameLatency))
        let active = engine.activeItemID.flatMap { engine.playback(for: $0) }
        var failures = vertical.failureCodes
        if origin.corpusVersion == nil { failures.append("missing_real_corpus") }
        if active?.hasAdvancingVideoFrames != true { failures.append("final_decoded_frames_not_advancing") }
        if telemetry.paths.reduce(0, { $0 + ($1.advancingDecodedFrameCount ?? 0) }) == 0 {
            failures.append("missing_advancing_decoded_frames")
        }
        if warmPlayback.count == 0 || warmDecoded.count == 0 {
            failures.append("missing_warm_frame_samples")
        }
        if let p95 = warmPlayback.p95Milliseconds,
           p95 > timingPolicy.warmPlaybackP95Seconds * 1_000 {
            failures.append("warm_playback_p95_exceeded")
        }
        if let p95 = warmDecoded.p95Milliseconds,
           p95 > timingPolicy.warmDecodedP95Seconds * 1_000 {
            failures.append("warm_decoded_p95_exceeded")
        }
        if telemetry.nativeAudio?.sampleCount == 0 || telemetry.nativeAudio == nil {
            failures.append("missing_native_audio_ownership")
        }
        if telemetry.nativeAudio?.ownershipViolationCount != 0
            || telemetry.nativeAudio?.maximumEligiblePlayers != 1 {
            failures.append("native_audio_ownership_violation")
        }
        let payloadLimit = configuration.maximumConcurrentBodies * configuration.maximumBodyBytes
        if origin.bodyBudget.maximumBodyCount > configuration.maximumConcurrentBodies
            || origin.bodyBudget.maximumBodyBytes > payloadLimit {
            failures.append("origin_payload_budget_exceeded")
        }
        return Self(
            schemaVersion: 1, qualificationKind: "real_audiovisual_feed_ui",
            corpusVersion: origin.corpusVersion, passed: failures.isEmpty, failureCodes: failures.sorted(),
            vertical: vertical,
            videoPaths: telemetry.paths.map {
                VideoPath(path: $0.path, decodedFirstFrameLatency: $0.decodedFirstFrameLatency,
                          playbackStartStages: $0.playbackStartStages,
                          sampledFrameCount: $0.decodedFrameCount, advancingFrameCount: $0.advancingDecodedFrameCount)
            },
            nativeAudio: telemetry.nativeAudio, originPayload: origin.bodyBudget,
            originBodyLimit: configuration.maximumConcurrentBodies, originPayloadByteLimit: payloadLimit,
            warmPlaybackStart: warmPlayback, warmDecodedFirstFrame: warmDecoded, coldDecodedFirstFrame: coldDecoded,
            finalFramesAdvancing: active?.hasAdvancingVideoFrames == true,
            timingProfile: timingPolicy.profile,
            warmPlaybackP95LimitMilliseconds: timingPolicy.warmPlaybackP95Seconds * 1_000,
            warmDecodedP95LimitMilliseconds: timingPolicy.warmDecodedP95Seconds * 1_000
        )
    }
}
