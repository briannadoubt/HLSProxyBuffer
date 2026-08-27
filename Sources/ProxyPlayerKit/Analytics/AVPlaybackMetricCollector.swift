#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Owns AVPlayerItem metrics across item replacement and exposes only the
/// sanitized, versioned analytics contract.
@MainActor
public final class AVPlaybackMetricCollector {
    public enum CollectionPath: String, Codable, Sendable {
        case none
        case nativeAVMetrics
        case legacyFallback
    }

    public struct Snapshot: Equatable, Codable, Sendable {
        public let collectionPath: CollectionPath
        public let observedItemCount: UInt64
        public let emittedEventCount: UInt64
        public let droppedEventCount: UInt64
        public let activeSourceCount: Int
        public let activeTaskCount: Int
        public let activeObserverCount: Int

        public static let empty = Self(
            collectionPath: .none,
            observedItemCount: 0,
            emittedEventCount: 0,
            droppedEventCount: 0,
            activeSourceCount: 0,
            activeTaskCount: 0,
            activeObserverCount: 0
        )
    }

    public let events: AsyncStream<PlaybackAnalytics.Event>
    public var snapshot: Snapshot {
        let resources = source?.resources ?? .empty
        return Snapshot(
            collectionPath: source?.path ?? .none,
            observedItemCount: observedItemCount,
            emittedEventCount: emittedEventCount,
            droppedEventCount: droppedEventCount,
            activeSourceCount: source == nil ? 0 : 1,
            activeTaskCount: resources.taskCount,
            activeObserverCount: (playerObservation == nil ? 0 : 1)
                + resources.observerCount
        )
    }

    private let correlation: PlaybackAnalytics.Correlation
    private let dimensions: PlaybackAnalytics.Dimensions
    private let clock: PlaybackAnalytics.TimelineClock
    private let sourceFactory: any AVPlaybackMetricSourceFactory
    private let continuation: AsyncStream<PlaybackAnalytics.Event>.Continuation

    private weak var player: AVPlayer?
    private weak var currentItem: AVPlayerItem?
    private var playerObservation: NSKeyValueObservation?
    private var source: (any AVPlaybackMetricSource)?
    private var generation: UInt64 = 0
    private var isFinished = false
    private var observedItemCount: UInt64 = 0
    private var emittedEventCount: UInt64 = 0
    private var droppedEventCount: UInt64 = 0

    public init(
        correlation: PlaybackAnalytics.Correlation,
        dimensions: PlaybackAnalytics.Dimensions = .empty,
        eventBufferCapacity: Int = 64
    ) {
        self.correlation = correlation
        self.dimensions = dimensions
        clock = PlaybackAnalytics.TimelineClock()
        sourceFactory = ProductionAVPlaybackMetricSourceFactory()
        let pair = AsyncStream.makeStream(
            of: PlaybackAnalytics.Event.self,
            bufferingPolicy: .bufferingNewest(min(max(1, eventBufferCapacity), 256))
        )
        events = pair.stream
        continuation = pair.continuation
    }

    init(
        correlation: PlaybackAnalytics.Correlation,
        dimensions: PlaybackAnalytics.Dimensions = .empty,
        eventBufferCapacity: Int = 64,
        clock: PlaybackAnalytics.TimelineClock,
        sourceFactory: any AVPlaybackMetricSourceFactory
    ) {
        self.correlation = correlation
        self.dimensions = dimensions
        self.clock = clock
        self.sourceFactory = sourceFactory
        let pair = AsyncStream.makeStream(
            of: PlaybackAnalytics.Event.self,
            bufferingPolicy: .bufferingNewest(min(max(1, eventBufferCapacity), 256))
        )
        events = pair.stream
        continuation = pair.continuation
    }

    /// Begins collection and automatically follows `currentItem` replacement.
    public func attach(to player: AVPlayer) {
        guard !isFinished else { return }
        detachPlayer()
        self.player = player
        playerObservation = player.observe(\.currentItem, options: [.initial, .new]) {
            [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.replaceSource(for: player.currentItem, player: player)
            }
        }
    }

    /// Cancels every task and observer and permanently finishes the event stream.
    public func stop() {
        guard !isFinished else { return }
        isFinished = true
        detachPlayer()
        continuation.finish()
    }

    isolated deinit {
        playerObservation?.invalidate()
        source?.stop()
        continuation.finish()
    }

    private func replaceSource(for item: AVPlayerItem?, player: AVPlayer) {
        guard !isFinished else { return }
        if currentItem === item, source != nil { return }

        generation &+= 1
        let sourceGeneration = generation
        source?.stop()
        source = nil
        currentItem = item

        guard let item else {
            return
        }

        observedItemCount = Self.saturatingAdd(observedItemCount, 1)
        let source = sourceFactory.makeSource(item: item, player: player)
        self.source = source
        source.start { [weak self, weak item] sample in
            guard let self,
                  let item,
                  !self.isFinished,
                  self.generation == sourceGeneration,
                  self.currentItem === item
            else {
                return
            }
            self.emit(sample)
        }
    }

    private func emit(_ sample: AVPlaybackMetricSample) {
        guard let event = try? PlaybackAnalytics.Event(
            correlation: correlation,
            timestamp: clock.timestamp(),
            source: .avFoundation,
            lifecycle: sample.lifecycle,
            priority: sample.priority,
            dimensions: dimensions,
            measurements: sample.measurements
        ) else {
            return
        }
        switch continuation.yield(event) {
        case .enqueued:
            emittedEventCount = Self.saturatingAdd(emittedEventCount, 1)
        case .dropped:
            emittedEventCount = Self.saturatingAdd(emittedEventCount, 1)
            droppedEventCount = Self.saturatingAdd(droppedEventCount, 1)
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    private func detachPlayer() {
        generation &+= 1
        source?.stop()
        source = nil
        currentItem = nil
        playerObservation?.invalidate()
        playerObservation = nil
        player = nil
    }

    private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let result = value.addingReportingOverflow(increment)
        return result.overflow ? .max : result.partialValue
    }
}

struct AVPlaybackMetricSourceResources: Equatable, Sendable {
    static let empty = Self(taskCount: 0, observerCount: 0)

    let taskCount: Int
    let observerCount: Int
}

@MainActor
protocol AVPlaybackMetricSource: AnyObject {
    var path: AVPlaybackMetricCollector.CollectionPath { get }
    var resources: AVPlaybackMetricSourceResources { get }

    func start(deliver: @escaping @MainActor @Sendable (AVPlaybackMetricSample) -> Void)
    func stop()
}

@MainActor
protocol AVPlaybackMetricSourceFactory: AnyObject {
    func makeSource(item: AVPlayerItem, player: AVPlayer) -> any AVPlaybackMetricSource
}

@MainActor
private final class ProductionAVPlaybackMetricSourceFactory: AVPlaybackMetricSourceFactory {
    func makeSource(item: AVPlayerItem, player: AVPlayer) -> any AVPlaybackMetricSource {
        if #available(
            iOS 18,
            tvOS 18,
            macOS 15,
            macCatalyst 18,
            visionOS 2,
            *
        ) {
            return NativeAVPlaybackMetricSource(item: item)
        }
        return LegacyAVPlaybackMetricSource(item: item, player: player)
    }
}

struct AVPlaybackMetricSample: Equatable, Sendable {
    let lifecycle: PlaybackAnalytics.Lifecycle
    let priority: PlaybackAnalytics.Priority
    let measurements: [PlaybackAnalytics.Measurement]
}

enum AVPlaybackMetricResourceKind: Sendable {
    case playlist
    case mediaSegment
    case contentKey
    case mediaResource
}

struct AVPlaybackMetricSummaryInput: Sendable {
    let recoverableErrorCount: Int
    let stallCount: Int
    let variantSwitchCount: Int
    let playbackDuration: TimeInterval
    let mediaResourceRequestCount: Int
    let stallRecoveryDuration: TimeInterval
    let startupDuration: TimeInterval
    let averageBitrate: Double
    let peakBitrate: Double
}

enum AVPlaybackMetricInput: Sendable {
    case initialLikelyToKeepUp(
        duration: TimeInterval,
        playlistRequestCount: Int,
        mediaSegmentRequestCount: Int,
        contentKeyRequestCount: Int
    )
    case likelyToKeepUp(duration: TimeInterval)
    case stall(previousRate: Double)
    case rateChanged(rate: Double, previousRate: Double)
    case seekStarted(rate: Double, previousRate: Double)
    case seekCompleted(rate: Double, previousRate: Double, didSeekInBuffer: Bool?)
    case variantSwitchStarted(averageBitrate: Double?, peakBitrate: Double?)
    case variantSwitched(succeeded: Bool, averageBitrate: Double?, peakBitrate: Double?)
    case resource(
        kind: AVPlaybackMetricResourceKind,
        duration: TimeInterval,
        byteCount: Int,
        wasCached: Bool,
        failed: Bool
    )
    case error(recovered: Bool)
    case playbackCompleted
    case summary(AVPlaybackMetricSummaryInput)
}

enum AVPlaybackMetricMapper {
    static func sample(
        from input: AVPlaybackMetricInput,
        mediaTime: TimeInterval? = nil
    ) -> AVPlaybackMetricSample {
        let mapped: AVPlaybackMetricSample
        switch input {
        case .initialLikelyToKeepUp(
            let duration,
            let playlistRequestCount,
            let mediaSegmentRequestCount,
            let contentKeyRequestCount
        ):
            mapped = .init(
                lifecycle: .ready,
                priority: .important,
                measurements: measurements([
                    ("initial_likely_to_keep_up", duration, .seconds),
                    ("playlist_request_count", Double(max(0, playlistRequestCount)), .count),
                    ("media_segment_request_count", Double(max(0, mediaSegmentRequestCount)), .count),
                    ("content_key_request_count", Double(max(0, contentKeyRequestCount)), .count),
                ])
            )
        case .likelyToKeepUp(let duration):
            mapped = .init(
                lifecycle: .recovered,
                priority: .important,
                measurements: measurements([
                    ("likely_to_keep_up", duration, .seconds),
                ])
            )
        case .stall(let previousRate):
            mapped = .init(
                lifecycle: .stalled,
                priority: .important,
                measurements: measurements([
                    ("stall_count", 1, .count),
                    ("previous_playback_rate", previousRate, .scalar),
                ])
            )
        case .rateChanged(let rate, let previousRate):
            mapped = .init(
                lifecycle: .rateChanged,
                priority: .routine,
                measurements: measurements([
                    ("playback_rate", rate, .scalar),
                    ("previous_playback_rate", previousRate, .scalar),
                ])
            )
        case .seekStarted(let rate, let previousRate):
            mapped = .init(
                lifecycle: .seekStarted,
                priority: .routine,
                measurements: measurements([
                    ("playback_rate", rate, .scalar),
                    ("previous_playback_rate", previousRate, .scalar),
                ])
            )
        case .seekCompleted(let rate, let previousRate, let didSeekInBuffer):
            var values: [(String, Double, PlaybackAnalytics.MeasurementUnit)] = [
                ("playback_rate", rate, .scalar),
                ("previous_playback_rate", previousRate, .scalar),
            ]
            if let didSeekInBuffer {
                values.append(("seek_in_buffer", didSeekInBuffer ? 1 : 0, .ratio))
            }
            mapped = .init(
                lifecycle: .seekCompleted,
                priority: .routine,
                measurements: measurements(values)
            )
        case .variantSwitchStarted(let averageBitrate, let peakBitrate):
            mapped = .init(
                lifecycle: .variantSwitchStarted,
                priority: .routine,
                measurements: bitrateMeasurements(
                    averageBitrate: averageBitrate,
                    peakBitrate: peakBitrate
                )
            )
        case .variantSwitched(let succeeded, let averageBitrate, let peakBitrate):
            var values = bitrateMeasurements(
                averageBitrate: averageBitrate,
                peakBitrate: peakBitrate
            )
            values += measurements([
                (succeeded ? "variant_switch_success_count" : "variant_switch_failure_count", 1, .count),
            ])
            mapped = .init(
                lifecycle: .variantSwitched,
                priority: succeeded ? .routine : .important,
                measurements: values
            )
        case .resource(let kind, let duration, let byteCount, let wasCached, let failed):
            let requestCountName = switch kind {
            case .playlist: "playlist_request_count"
            case .mediaSegment: "media_segment_request_count"
            case .contentKey: "content_key_request_count"
            case .mediaResource: "media_resource_request_count"
            }
            mapped = .init(
                lifecycle: .resourceCompleted,
                priority: failed ? .important : .routine,
                measurements: measurements([
                    (requestCountName, 1, .count),
                    ("request_duration", max(0, duration), .seconds),
                    ("request_bytes", Double(max(0, byteCount)), .bytes),
                    (wasCached ? "cache_hit_count" : "cache_miss_count", 1, .count),
                    (failed ? "request_failure_count" : "request_success_count", 1, .count),
                ])
            )
        case .error(let recovered):
            mapped = .init(
                lifecycle: recovered ? .recovered : .failed,
                priority: recovered ? .important : .critical,
                measurements: measurements([
                    (recovered ? "recoverable_error_count" : "fatal_error_count", 1, .count),
                ])
            )
        case .playbackCompleted:
            mapped = .init(
                lifecycle: .completed,
                priority: .critical,
                measurements: measurements([("completion_count", 1, .count)])
            )
        case .summary(let summary):
            mapped = .init(
                lifecycle: .summaryEmitted,
                priority: .critical,
                measurements: measurements([
                    ("recoverable_error_count", Double(max(0, summary.recoverableErrorCount)), .count),
                    ("stall_count", Double(max(0, summary.stallCount)), .count),
                    ("variant_switch_count", Double(max(0, summary.variantSwitchCount)), .count),
                    ("watch_duration", max(0, summary.playbackDuration), .seconds),
                    ("media_resource_request_count", Double(max(0, summary.mediaResourceRequestCount)), .count),
                    ("stall_recovery_duration", max(0, summary.stallRecoveryDuration), .seconds),
                    ("startup_duration", max(0, summary.startupDuration), .seconds),
                    ("average_bitrate", max(0, summary.averageBitrate), .bitsPerSecond),
                    ("peak_bitrate", max(0, summary.peakBitrate), .bitsPerSecond),
                ])
            )
        }

        guard let mediaTime, mediaTime.isFinite, mediaTime >= 0 else { return mapped }
        var values = mapped.measurements
        values += measurements([("media_time", mediaTime, .seconds)])
        return .init(
            lifecycle: mapped.lifecycle,
            priority: mapped.priority,
            measurements: values
        )
    }

    private static func bitrateMeasurements(
        averageBitrate: Double?,
        peakBitrate: Double?
    ) -> [PlaybackAnalytics.Measurement] {
        var values: [(String, Double, PlaybackAnalytics.MeasurementUnit)] = []
        if let averageBitrate {
            values.append(("average_bitrate", max(0, averageBitrate), .bitsPerSecond))
        }
        if let peakBitrate {
            values.append(("peak_bitrate", max(0, peakBitrate), .bitsPerSecond))
        }
        return measurements(values)
    }

    private static func measurements(
        _ values: [(String, Double, PlaybackAnalytics.MeasurementUnit)]
    ) -> [PlaybackAnalytics.Measurement] {
        values.compactMap { name, value, unit in
            guard value.isFinite,
                  let name = try? PlaybackAnalytics.MeasurementName(name)
            else {
                return nil
            }
            return try? PlaybackAnalytics.Measurement(name: name, value: value, unit: unit)
        }
    }
}

@available(iOS 18, tvOS 18, macOS 15, macCatalyst 18, visionOS 2, *)
@MainActor
private final class NativeAVPlaybackMetricSource: AVPlaybackMetricSource {
    let path = AVPlaybackMetricCollector.CollectionPath.nativeAVMetrics
    var resources: AVPlaybackMetricSourceResources {
        .init(taskCount: task == nil ? 0 : 1, observerCount: 0)
    }

    private weak var item: AVPlayerItem?
    private var task: Task<Void, Never>?

    init(item: AVPlayerItem) {
        self.item = item
    }

    func start(deliver: @escaping @MainActor @Sendable (AVPlaybackMetricSample) -> Void) {
        guard task == nil, let item else { return }
        task = Task { @MainActor [weak self, weak item] in
            defer { self?.task = nil }
            guard let item else { return }
            do {
                for try await event in item.allMetrics() {
                    guard !Task.isCancelled else { break }
                    guard self != nil,
                          let input = NativeAVPlaybackMetricProjector.input(from: event)
                    else {
                        continue
                    }
                    deliver(AVPlaybackMetricMapper.sample(
                        from: input,
                        mediaTime: event.mediaTime.seconds
                    ))
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@available(iOS 18, tvOS 18, macOS 15, macCatalyst 18, visionOS 2, *)
private enum NativeAVPlaybackMetricProjector {
    static func input(from event: AVMetricEvent) -> AVPlaybackMetricInput? {
        switch event {
        case let value as AVMetricPlayerItemInitialLikelyToKeepUpEvent:
            return .initialLikelyToKeepUp(
                duration: value.timeTaken,
                playlistRequestCount: value.playlistRequestEvents.count,
                mediaSegmentRequestCount: value.mediaSegmentRequestEvents.count,
                contentKeyRequestCount: value.contentKeyRequestEvents.count
            )
        case let value as AVMetricPlayerItemLikelyToKeepUpEvent:
            return .likelyToKeepUp(duration: value.timeTaken)
        case let value as AVMetricPlayerItemSeekDidCompleteEvent:
            return .seekCompleted(
                rate: value.rate,
                previousRate: value.previousRate,
                didSeekInBuffer: value.didSeekInBuffer
            )
        case let value as AVMetricPlayerItemSeekEvent:
            return .seekStarted(rate: value.rate, previousRate: value.previousRate)
        case let value as AVMetricPlayerItemStallEvent:
            return .stall(previousRate: value.previousRate)
        case let value as AVMetricPlayerItemRateChangeEvent:
            return .rateChanged(rate: value.rate, previousRate: value.previousRate)
        case let value as AVMetricPlayerItemVariantSwitchEvent:
            return .variantSwitched(
                succeeded: value.didSucceed,
                averageBitrate: value.toVariant.averageBitRate,
                peakBitrate: value.toVariant.peakBitRate
            )
        case let value as AVMetricPlayerItemVariantSwitchStartEvent:
            return .variantSwitchStarted(
                averageBitrate: value.toVariant.averageBitRate,
                peakBitrate: value.toVariant.peakBitRate
            )
        case let value as AVMetricHLSMediaSegmentRequestEvent:
            return resourceInput(
                kind: .mediaSegment,
                fallbackBytes: value.byteRange.length,
                resource: value.mediaResourceRequestEvent
            )
        case let value as AVMetricHLSPlaylistRequestEvent:
            return resourceInput(
                kind: .playlist,
                fallbackBytes: 0,
                resource: value.mediaResourceRequestEvent
            )
        case let value as AVMetricContentKeyRequestEvent:
            return resourceInput(
                kind: .contentKey,
                fallbackBytes: 0,
                resource: value.mediaResourceRequestEvent
            )
        case let value as AVMetricMediaResourceRequestEvent:
            return resourceInput(
                kind: .mediaResource,
                fallbackBytes: value.byteRange.length,
                resource: value
            )
        case let value as AVMetricErrorEvent:
            return .error(recovered: value.didRecover)
        case let value as AVMetricPlayerItemPlaybackSummaryEvent:
            return .summary(.init(
                recoverableErrorCount: value.recoverableErrorCount,
                stallCount: value.stallCount,
                variantSwitchCount: value.variantSwitchCount,
                playbackDuration: TimeInterval(value.playbackDuration),
                mediaResourceRequestCount: value.mediaResourceRequestCount,
                stallRecoveryDuration: value.timeSpentRecoveringFromStall,
                startupDuration: value.timeSpentInInitialStartup,
                averageBitrate: Double(value.timeWeightedAverageBitrate),
                peakBitrate: Double(value.timeWeightedPeakBitrate)
            ))
        default:
            return nil
        }
    }

    private static func resourceInput(
        kind: AVPlaybackMetricResourceKind,
        fallbackBytes: Int,
        resource: AVMetricMediaResourceRequestEvent?
    ) -> AVPlaybackMetricInput {
        guard let resource else {
            return .resource(
                kind: kind,
                duration: 0,
                byteCount: fallbackBytes,
                wasCached: false,
                failed: false
            )
        }
        return .resource(
            kind: kind,
            duration: max(0, resource.responseEndTime.timeIntervalSince(
                resource.requestStartTime
            )),
            byteCount: max(fallbackBytes, resource.byteRange.length),
            wasCached: resource.wasReadFromCache,
            failed: resource.errorEvent != nil
        )
    }
}

@MainActor
final class LegacyAVPlaybackMetricSource: AVPlaybackMetricSource {
    let path = AVPlaybackMetricCollector.CollectionPath.legacyFallback
    var resources: AVPlaybackMetricSourceResources {
        .init(taskCount: 0, observerCount: observations.count + notificationTokens.count)
    }

    private weak var item: AVPlayerItem?
    private weak var player: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var deliver: (@MainActor @Sendable (AVPlaybackMetricSample) -> Void)?
    private var hasSeenLikelyToKeepUp = false
    private var hasEmittedFatalFailure = false

    init(item: AVPlayerItem, player: AVPlayer) {
        self.item = item
        self.player = player
    }

    func start(deliver: @escaping @MainActor @Sendable (AVPlaybackMetricSample) -> Void) {
        guard observations.isEmpty, notificationTokens.isEmpty,
              let item, let player
        else {
            return
        }
        self.deliver = deliver

        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) {
            [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let input: AVPlaybackMetricInput = self.hasSeenLikelyToKeepUp
                    ? .likelyToKeepUp(duration: 0)
                    : .initialLikelyToKeepUp(
                        duration: 0,
                        playlistRequestCount: 0,
                        mediaSegmentRequestCount: 0,
                        contentKeyRequestCount: 0
                    )
                self.hasSeenLikelyToKeepUp = true
                self.deliver?(AVPlaybackMetricMapper.sample(from: input))
            }
        })
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.emitFatalFailureOnce() }
        })
        observations.append(player.observe(\.rate, options: [.old, .new]) { [weak self] _, change in
            guard let rate = change.newValue else { return }
            let previousRate = change.oldValue ?? 0
            Task { @MainActor [weak self] in
                self?.deliver?(AVPlaybackMetricMapper.sample(from: .rateChanged(
                    rate: Double(rate),
                    previousRate: Double(previousRate)
                )))
            }
        })

        observe(.AVPlayerItemPlaybackStalled, item: item) { .stall(previousRate: 0) }
        observe(.AVPlayerItemTimeJumped, item: item) {
            .seekCompleted(rate: 0, previousRate: 0, didSeekInBuffer: nil)
        }
        observe(.AVPlayerItemDidPlayToEndTime, item: item) { .playbackCompleted }
        observe(.AVPlayerItemFailedToPlayToEndTime, item: item) { [weak self] in
            self?.emitFatalFailureOnce()
            return nil
        }
        observe(.AVPlayerItemNewErrorLogEntry, item: item) {
            .error(recovered: true)
        }
        observe(.AVPlayerItemNewAccessLogEntry, item: item) { [weak item] in
            guard let event = item?.accessLog()?.events.last else { return nil }
            return .resource(
                kind: .mediaResource,
                duration: max(0, event.transferDuration),
                byteCount: Int(clamping: event.numberOfBytesTransferred),
                wasCached: false,
                failed: false
            )
        }
    }

    func stop() {
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        deliver = nil
        hasSeenLikelyToKeepUp = false
        hasEmittedFatalFailure = false
    }

    isolated deinit {
        for observation in observations { observation.invalidate() }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func observe(
        _ name: Notification.Name,
        item: AVPlayerItem,
        input: @escaping @MainActor @Sendable () -> AVPlaybackMetricInput?
    ) {
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: name,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let input = input() else { return }
                self.deliver?(AVPlaybackMetricMapper.sample(from: input))
            }
        })
    }

    private func emitFatalFailureOnce() {
        guard !hasEmittedFatalFailure else { return }
        hasEmittedFatalFailure = true
        deliver?(AVPlaybackMetricMapper.sample(from: .error(recovered: false)))
    }
}
#endif
