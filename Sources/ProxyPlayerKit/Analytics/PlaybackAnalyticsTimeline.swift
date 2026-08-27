import Foundation
import HLSCore

/// An engine-owned, bounded merger for playback signals from every layer.
///
/// Attempts use opaque identities and generation tokens. A token remains stable
/// while a prepared item moves through prediction, focus, and pooled-player
/// handoff; once retired, it can never publish into a newer attempt.
@MainActor
public final class PlaybackAnalyticsTimeline {
    public struct Configuration: Equatable, Sendable {
        public let eventBufferCapacity: Int
        public let summaryBufferCapacity: Int
        public let maximumActiveAttemptCount: Int

        public init(
            eventBufferCapacity: Int = 128,
            summaryBufferCapacity: Int = 64,
            maximumActiveAttemptCount: Int = 16
        ) {
            self.eventBufferCapacity = min(max(1, eventBufferCapacity), 512)
            self.summaryBufferCapacity = min(max(1, summaryBufferCapacity), 256)
            self.maximumActiveAttemptCount = min(max(1, maximumActiveAttemptCount), 64)
        }
    }

    public enum Reuse: String, Codable, Sendable {
        case cold
        case warm
    }

    public enum Intent: String, Codable, Sendable {
        case focused
        case predicted
    }

    public enum MediaKind: String, Codable, Sendable {
        case videoOnDemand = "vod"
        case live
        case stitched
    }

    public enum NetworkLeg: String, Codable, Sendable {
        case notApplicable = "none"
        case playerToLocalProxy = "player_proxy"
        case localProxyToOrigin = "proxy_origin"
    }

    public enum CacheTier: String, Codable, Sendable {
        case notApplicable = "none"
        case memory
        case disk
        case origin
    }

    public struct Attribution: Equatable, Codable, Sendable {
        public let reuse: Reuse
        public let intent: Intent
        public let mediaKind: MediaKind
        public let networkLeg: NetworkLeg
        public let cacheTier: CacheTier

        public init(
            reuse: Reuse,
            intent: Intent,
            mediaKind: MediaKind,
            networkLeg: NetworkLeg = .notApplicable,
            cacheTier: CacheTier = .notApplicable
        ) {
            self.reuse = reuse
            self.intent = intent
            self.mediaKind = mediaKind
            self.networkLeg = networkLeg
            self.cacheTier = cacheTier
        }
    }

    public struct Attempt: Hashable, Sendable {
        public let correlation: PlaybackAnalytics.Correlation
        fileprivate let token: UUID

        fileprivate init(
            correlation: PlaybackAnalytics.Correlation,
            token: UUID
        ) {
            self.correlation = correlation
            self.token = token
        }
    }

    public struct Snapshot: Equatable, Codable, Sendable {
        public let activeAttemptCount: Int
        public let maximumActiveAttemptCount: Int
        public let emittedEventCount: UInt64
        public let droppedEventCount: UInt64
        public let emittedSummaryCount: UInt64
        public let droppedSummaryCount: UInt64
        public let staleEventCount: UInt64
        public let evictedAttemptCount: UInt64
        public let lastSequence: UInt64

        public static let empty = Self(
            activeAttemptCount: 0,
            maximumActiveAttemptCount: 0,
            emittedEventCount: 0,
            droppedEventCount: 0,
            emittedSummaryCount: 0,
            droppedSummaryCount: 0,
            staleEventCount: 0,
            evictedAttemptCount: 0,
            lastSequence: 0
        )
    }

    public let events: AsyncStream<PlaybackAnalytics.Event>
    /// One terminal summary for every attempt, including evicted and unfinished attempts.
    public let summaries: AsyncStream<PlaybackAnalytics.Summary>
    public var snapshot: Snapshot {
        Snapshot(
            activeAttemptCount: states.count,
            maximumActiveAttemptCount: configuration.maximumActiveAttemptCount,
            emittedEventCount: emittedEventCount,
            droppedEventCount: droppedEventCount,
            emittedSummaryCount: emittedSummaryCount,
            droppedSummaryCount: droppedSummaryCount,
            staleEventCount: staleEventCount,
            evictedAttemptCount: evictedAttemptCount,
            lastSequence: sequence
        )
    }

    let clock: PlaybackAnalytics.TimelineClock

    private struct State {
        let attempt: Attempt
        var attribution: Attribution
        var streaming = HLSStreamingTelemetry.Snapshot.empty
        var summarizer: PlaybackSessionSummarizer
        let ordinal: UInt64
    }

    private let configuration: Configuration
    private let sessionID: PlaybackAnalytics.SessionID
    private let continuation: AsyncStream<PlaybackAnalytics.Event>.Continuation
    private let summaryContinuation: AsyncStream<PlaybackAnalytics.Summary>.Continuation
    private var states: [UUID: State] = [:]
    private var sequence: UInt64 = 0
    private var nextAttemptOrdinal: UInt64 = 0
    private var emittedEventCount: UInt64 = 0
    private var droppedEventCount: UInt64 = 0
    private var emittedSummaryCount: UInt64 = 0
    private var droppedSummaryCount: UInt64 = 0
    private var staleEventCount: UInt64 = 0
    private var evictedAttemptCount: UInt64 = 0
    private var isFinished = false

    public init(
        sessionID: PlaybackAnalytics.SessionID = .init(),
        configuration: Configuration = .init()
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        clock = PlaybackAnalytics.TimelineClock()
        let pair = AsyncStream.makeStream(
            of: PlaybackAnalytics.Event.self,
            bufferingPolicy: .bufferingNewest(configuration.eventBufferCapacity)
        )
        events = pair.stream
        continuation = pair.continuation
        let summaryPair = AsyncStream.makeStream(
            of: PlaybackAnalytics.Summary.self,
            bufferingPolicy: .bufferingNewest(configuration.summaryBufferCapacity)
        )
        summaries = summaryPair.stream
        summaryContinuation = summaryPair.continuation
    }

    init(
        sessionID: PlaybackAnalytics.SessionID,
        configuration: Configuration,
        clock: PlaybackAnalytics.TimelineClock
    ) {
        self.sessionID = sessionID
        self.configuration = configuration
        self.clock = clock
        let pair = AsyncStream.makeStream(
            of: PlaybackAnalytics.Event.self,
            bufferingPolicy: .bufferingNewest(configuration.eventBufferCapacity)
        )
        events = pair.stream
        continuation = pair.continuation
        let summaryPair = AsyncStream.makeStream(
            of: PlaybackAnalytics.Summary.self,
            bufferingPolicy: .bufferingNewest(configuration.summaryBufferCapacity)
        )
        summaries = summaryPair.stream
        summaryContinuation = summaryPair.continuation
    }

    /// Starts one opaque attempt and emits its first ordered lifecycle event.
    @discardableResult
    public func beginAttempt(attribution: Attribution) -> Attempt {
        guard !isFinished else {
            staleEventCount = Self.saturatingAdd(staleEventCount, 1)
            return Attempt(
                correlation: .init(
                    sessionID: sessionID,
                    playbackID: .init(),
                    itemID: .init()
                ),
                token: UUID()
            )
        }
        if states.count >= configuration.maximumActiveAttemptCount,
           let oldest = states.values.min(by: { $0.ordinal < $1.ordinal }) {
            finalize(
                oldest.attempt,
                reason: .incomplete,
                endedAt: clock.timestamp()
            )
            evictedAttemptCount = Self.saturatingAdd(evictedAttemptCount, 1)
        }

        nextAttemptOrdinal = Self.saturatingAdd(nextAttemptOrdinal, 1)
        let startedAt = clock.timestamp()
        let attempt = Attempt(
            correlation: .init(
                sessionID: sessionID,
                playbackID: .init(),
                itemID: .init()
            ),
            token: UUID()
        )
        states[attempt.token] = State(
            attempt: attempt,
            attribution: attribution,
            summarizer: PlaybackSessionSummarizer(
                correlation: attempt.correlation,
                startedAt: startedAt
            ),
            ordinal: nextAttemptOrdinal
        )
        emit(
            source: .feedEngine,
            lifecycle: .preparing,
            priority: .important,
            measurements: [],
            attempt: attempt
        )
        return attempt
    }

    /// Changes bounded attribution without changing correlation lineage.
    public func updateAttribution(_ attribution: Attribution, for attempt: Attempt) {
        guard var state = validState(for: attempt) else { return }
        state.attribution = attribution
        states[attempt.token] = state
    }

    /// Records an already-sanitized lifecycle signal.
    public func record(
        source: PlaybackAnalytics.Source,
        lifecycle: PlaybackAnalytics.Lifecycle,
        priority: PlaybackAnalytics.Priority = .routine,
        measurements: [PlaybackAnalytics.Measurement] = [],
        attempt: Attempt,
        networkLeg: NetworkLeg? = nil,
        cacheTier: CacheTier? = nil
    ) {
        emit(
            source: source,
            lifecycle: lifecycle,
            priority: priority,
            measurements: measurements,
            attempt: attempt,
            networkLeg: networkLeg,
            cacheTier: cacheTier
        )
    }

    /// Maps fixed-memory feed telemetry into the shared event contract.
    public func record(feed event: HLSFeedTelemetry.Event, attempt: Attempt) {
        guard var state = validState(for: attempt) else { return }
        if let path = event.path {
            state.attribution = Self.attribution(from: path, preserving: state.attribution)
            states[attempt.token] = state
        }
        switch event.payload {
        case .firstFrame(let latency):
            emit(
                source: .feedEngine,
                lifecycle: .playbackStarted,
                priority: .important,
                measurements: Self.measurements([
                    ("first_frame_latency", latency, .seconds),
                ]),
                attempt: attempt
            )
        case .stall(let duration):
            emit(
                source: .feedEngine,
                lifecycle: .stalled,
                priority: .important,
                measurements: Self.measurements([
                    ("stall_count", 1, .count),
                    ("stall_duration", duration, .seconds),
                ]),
                attempt: attempt
            )
        case .cache(let hits, let misses, let avoidedBytes):
            emit(
                source: .cache,
                lifecycle: .resourceCompleted,
                measurements: Self.measurements([
                    ("cache_hit_count", Double(max(0, hits)), .count),
                    ("cache_miss_count", Double(max(0, misses)), .count),
                    ("origin_bytes_avoided", Double(max(0, avoidedBytes)), .bytes),
                ]),
                attempt: attempt
            )
        case .cancellation(let latency, let outcome):
            let name = switch outcome {
            case .acknowledged: "cancellation_acknowledged_count"
            case .late: "cancellation_late_count"
            case .failed: "cancellation_failure_count"
            }
            emit(
                source: .scheduler,
                lifecycle: .cancelled,
                priority: .important,
                measurements: Self.measurements([
                    (name, 1, .count),
                    ("cancellation_latency", latency, .seconds),
                ]),
                attempt: attempt
            )
        case .handoff(let wasReady, let succeeded):
            emit(
                source: .feedEngine,
                lifecycle: succeeded ? .handoffCompleted : .handoffStarted,
                priority: .important,
                measurements: Self.measurements([
                    ("handoff_attempt_count", 1, .count),
                    ("handoff_ready_count", wasReady ? 1 : 0, .count),
                    ("handoff_success_count", succeeded ? 1 : 0, .count),
                ]),
                attempt: attempt
            )
        case .resources(let memory, let disk, let players, let proxies):
            emit(
                source: .feedEngine,
                lifecycle: .resourceCompleted,
                measurements: Self.measurements([
                    ("memory_resident_bytes", Double(max(0, memory)), .bytes),
                    ("disk_resident_bytes", Double(max(0, disk)), .bytes),
                    ("player_pool_occupancy", Double(max(0, players)), .count),
                    ("proxy_pool_occupancy", Double(max(0, proxies)), .count),
                ]),
                attempt: attempt
            )
        }
    }

    /// Records preparation reuse and origin work without retaining source URLs.
    public func record(prepared item: FeedPreparedItem, attempt: Attempt) {
        guard validState(for: attempt) != nil else { return }
        emit(
            source: .origin,
            lifecycle: .resourceCompleted,
            priority: .important,
            measurements: Self.measurements([
                ("prepared_resource_count", Double(item.preparedResourceCount), .count),
                ("prepared_bytes", Double(item.preparedByteCount), .bytes),
                ("cache_hit_count", Double(item.cacheHitCount), .count),
                ("origin_request_count", Double(item.originFetchCount), .count),
                ("origin_bytes", Double(item.originFetchByteCount), .bytes),
                ("origin_bytes_avoided", Double(item.cacheHitByteCount), .bytes),
            ]),
            attempt: attempt,
            networkLeg: .localProxyToOrigin,
            cacheTier: item.originFetchCount > 0 ? .origin : nil
        )
    }

    /// Adapts cumulative proxy/origin telemetry as non-negative deltas.
    public func record(
        streaming snapshot: HLSStreamingTelemetry.Snapshot,
        attempt: Attempt
    ) {
        guard var state = validState(for: attempt) else { return }
        let previous = state.streaming
        state.streaming = snapshot
        states[attempt.token] = state

        let fetchCount = Self.delta(
            snapshot.segmentFetchLatency.count,
            previous.segmentFetchLatency.count
        )
        let originBytes = Self.delta(snapshot.originByteCount, previous.originByteCount)
        let retryCount = Self.delta(snapshot.originRetryCount, previous.originRetryCount)
        let errorCount = Self.delta(
            Self.total(snapshot.fetchErrorCounts),
            Self.total(previous.fetchErrorCounts)
        )
        if fetchCount > 0 || originBytes > 0 || retryCount > 0 || errorCount > 0 {
            emit(
                source: .origin,
                lifecycle: .resourceCompleted,
                measurements: Self.measurements([
                    ("origin_request_count", Double(fetchCount), .count),
                    ("origin_bytes", Double(originBytes), .bytes),
                    ("origin_retry_count", Double(retryCount), .count),
                    ("origin_error_count", Double(errorCount), .count),
                ]),
                attempt: attempt,
                networkLeg: .localProxyToOrigin,
                cacheTier: .origin
            )
        }

        let cacheHits = Self.delta(snapshot.cacheHitCount, previous.cacheHitCount)
        let cacheMisses = Self.delta(snapshot.cacheMissCount, previous.cacheMissCount)
        let memoryHits = Self.delta(
            snapshot.memoryCacheHitCount,
            previous.memoryCacheHitCount
        )
        let diskHits = Self.delta(snapshot.diskCacheHitCount, previous.diskCacheHitCount)
        let classifiedHits = min(cacheHits, Self.saturatingAdd(memoryHits, diskHits))
        let unclassifiedHits = cacheHits - classifiedHits
        if memoryHits > 0 {
            emit(
                source: .cache,
                lifecycle: .resourceCompleted,
                measurements: Self.measurements([
                    ("cache_hit_count", Double(memoryHits), .count),
                ]),
                attempt: attempt,
                cacheTier: .memory
            )
        }
        if diskHits > 0 {
            emit(
                source: .cache,
                lifecycle: .resourceCompleted,
                measurements: Self.measurements([
                    ("cache_hit_count", Double(diskHits), .count),
                ]),
                attempt: attempt,
                cacheTier: .disk
            )
        }
        if unclassifiedHits > 0 || cacheMisses > 0 {
            emit(
                source: .cache,
                lifecycle: .resourceCompleted,
                measurements: Self.measurements([
                    ("cache_hit_count", Double(unclassifiedHits), .count),
                    ("cache_miss_count", Double(cacheMisses), .count),
                ]),
                attempt: attempt
            )
        }

        let variantSwitches = Self.delta(
            Self.total(snapshot.variantSwitchReasonCounts),
            Self.total(previous.variantSwitchReasonCounts)
        )
        if variantSwitches > 0 {
            emit(
                source: .player,
                lifecycle: .variantSwitched,
                measurements: Self.measurements([
                    ("variant_switch_count", Double(variantSwitches), .count),
                ]),
                attempt: attempt
            )
        }

        if snapshot.liveEdgeDistanceSeconds != previous.liveEdgeDistanceSeconds,
           let distance = snapshot.liveEdgeDistanceSeconds {
            emit(
                source: .player,
                lifecycle: .liveEdgeChanged,
                measurements: Self.measurements([
                    ("live_edge_distance", distance, .seconds),
                ]),
                attempt: attempt
            )
        }

        if snapshot.schedulerScheduledCount != previous.schedulerScheduledCount
            || snapshot.schedulerReadyCount != previous.schedulerReadyCount
            || snapshot.schedulerFailureCount != previous.schedulerFailureCount
            || snapshot.schedulerReadyPartCount != previous.schedulerReadyPartCount {
            emit(
                source: .scheduler,
                lifecycle: .ready,
                measurements: Self.measurements([
                    ("scheduled_resource_count", Double(snapshot.schedulerScheduledCount), .count),
                    ("ready_resource_count", Double(snapshot.schedulerReadyCount), .count),
                    ("scheduler_failure_count", Double(snapshot.schedulerFailureCount), .count),
                    ("ready_part_count", Double(snapshot.schedulerReadyPartCount), .count),
                ]),
                attempt: attempt
            )
        }
    }

    /// Maps player observable state without retaining error text.
    public func record(
        player state: PlayerState,
        previous: PlayerState? = nil,
        attempt: Attempt
    ) {
        let lifecycle: PlaybackAnalytics.Lifecycle
        let priority: PlaybackAnalytics.Priority
        switch state.status {
        case .idle:
            lifecycle = .paused
            priority = .routine
        case .buffering:
            lifecycle = previous?.status == .ready ? .stalled : .preparing
            priority = .important
        case .ready:
            lifecycle = previous?.status == .buffering ? .recovered : .ready
            priority = .important
        case .failed:
            lifecycle = .failed
            priority = .critical
        }
        var values: [(String, Double, PlaybackAnalytics.MeasurementUnit)] = [
            ("buffer_depth", state.bufferDepthSeconds, .seconds),
        ]
        if let distance = state.livePlayback?.liveEdgeDistanceSeconds {
            values.append(("live_edge_distance", distance, .seconds))
        }
        emit(
            source: .player,
            lifecycle: lifecycle,
            priority: priority,
            measurements: Self.measurements(values),
            attempt: attempt
        )
    }

    /// Re-correlates one sanitized AVFoundation event into this ordered clock.
    public func record(
        avFoundation event: PlaybackAnalytics.Event,
        attempt: Attempt
    ) {
        guard event.correlation == attempt.correlation else {
            staleEventCount = Self.saturatingAdd(staleEventCount, 1)
            return
        }
        emit(
            source: .avFoundation,
            lifecycle: event.lifecycle,
            priority: event.priority,
            measurements: event.measurements,
            attempt: attempt,
            networkLeg: .playerToLocalProxy
        )
    }

    public func recordStitchedBoundary(
        succeeded: Bool,
        attempt: Attempt
    ) {
        emit(
            source: .player,
            lifecycle: .stitchedBoundary,
            priority: succeeded ? .important : .critical,
            measurements: Self.measurements([
                (succeeded ? "stitched_boundary_success_count" : "stitched_boundary_failure_count", 1, .count),
            ]),
            attempt: attempt
        )
    }

    /// Emits a terminal lifecycle and permanently retires the attempt token.
    public func end(
        _ attempt: Attempt,
        lifecycle: PlaybackAnalytics.Lifecycle,
        priority: PlaybackAnalytics.Priority = .critical
    ) {
        guard states[attempt.token]?.attempt == attempt else {
            staleEventCount = Self.saturatingAdd(staleEventCount, 1)
            return
        }
        emit(
            source: .feedEngine,
            lifecycle: lifecycle,
            priority: priority,
            measurements: [],
            attempt: attempt
        )
        finalize(
            attempt,
            reason: Self.terminalReason(for: lifecycle),
            endedAt: clock.timestamp()
        )
    }

    /// Emits the matching terminal lifecycle and a single typed summary.
    public func end(
        _ attempt: Attempt,
        reason: PlaybackAnalytics.TerminalReason,
        priority: PlaybackAnalytics.Priority = .critical
    ) {
        guard states[attempt.token]?.attempt == attempt else {
            staleEventCount = Self.saturatingAdd(staleEventCount, 1)
            return
        }
        emit(
            source: .feedEngine,
            lifecycle: Self.lifecycle(for: reason),
            priority: priority,
            measurements: [],
            attempt: attempt
        )
        finalize(attempt, reason: reason, endedAt: clock.timestamp())
    }

    public func finish() {
        guard !isFinished else { return }
        for state in states.values.sorted(by: { $0.ordinal < $1.ordinal }) {
            finalize(
                state.attempt,
                reason: .incomplete,
                endedAt: clock.timestamp()
            )
        }
        isFinished = true
        continuation.finish()
        summaryContinuation.finish()
    }

    func dimensions(
        for attempt: Attempt,
        networkLeg: NetworkLeg? = nil,
        cacheTier: CacheTier? = nil
    ) -> PlaybackAnalytics.Dimensions {
        guard let state = states[attempt.token], state.attempt == attempt else { return .empty }
        var attribution = state.attribution
        if let networkLeg {
            attribution = .init(
                reuse: attribution.reuse,
                intent: attribution.intent,
                mediaKind: attribution.mediaKind,
                networkLeg: networkLeg,
                cacheTier: cacheTier ?? attribution.cacheTier
            )
        } else if let cacheTier {
            attribution = .init(
                reuse: attribution.reuse,
                intent: attribution.intent,
                mediaKind: attribution.mediaKind,
                networkLeg: attribution.networkLeg,
                cacheTier: cacheTier
            )
        }
        return Self.dimensions(from: attribution)
    }

    func isActive(_ attempt: Attempt) -> Bool {
        states[attempt.token]?.attempt == attempt
    }

    private func validState(for attempt: Attempt) -> State? {
        guard !isFinished,
              let state = states[attempt.token],
              state.attempt == attempt
        else {
            staleEventCount = Self.saturatingAdd(staleEventCount, 1)
            return nil
        }
        return state
    }

    private func emit(
        source: PlaybackAnalytics.Source,
        lifecycle: PlaybackAnalytics.Lifecycle,
        priority: PlaybackAnalytics.Priority = .routine,
        measurements: [PlaybackAnalytics.Measurement],
        attempt: Attempt,
        networkLeg: NetworkLeg? = nil,
        cacheTier: CacheTier? = nil
    ) {
        guard validState(for: attempt) != nil else { return }
        sequence = Self.saturatingAdd(sequence, 1)
        let withoutSequence = measurements.filter {
            $0.name.encodedValue != "timeline_sequence"
        }
        let sequenceMeasurement = Self.measurements([
            ("timeline_sequence", Double(sequence), .count),
        ])
        guard let event = try? PlaybackAnalytics.Event(
            correlation: attempt.correlation,
            timestamp: clock.timestamp(),
            source: source,
            lifecycle: lifecycle,
            priority: priority,
            dimensions: dimensions(
                for: attempt,
                networkLeg: networkLeg,
                cacheTier: cacheTier
            ),
            measurements: withoutSequence + sequenceMeasurement
        ) else {
            return
        }
        if var state = states[attempt.token] {
            try? state.summarizer.record(event)
            states[attempt.token] = state
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

    private func finalize(
        _ attempt: Attempt,
        reason: PlaybackAnalytics.TerminalReason,
        endedAt: PlaybackAnalytics.Timestamp
    ) {
        guard var state = states[attempt.token], state.attempt == attempt else { return }
        let summary = try? state.summarizer.finish(
            reason: reason,
            endedAt: endedAt,
            dimensions: Self.dimensions(from: state.attribution)
        )
        states.removeValue(forKey: attempt.token)
        guard let summary else { return }

        switch summaryContinuation.yield(summary) {
        case .enqueued:
            emittedSummaryCount = Self.saturatingAdd(emittedSummaryCount, 1)
        case .dropped:
            emittedSummaryCount = Self.saturatingAdd(emittedSummaryCount, 1)
            droppedSummaryCount = Self.saturatingAdd(droppedSummaryCount, 1)
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    private static func terminalReason(
        for lifecycle: PlaybackAnalytics.Lifecycle
    ) -> PlaybackAnalytics.TerminalReason {
        switch lifecycle {
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case .backgrounded:
            .backgrounded
        case .failed:
            .failed
        default:
            .incomplete
        }
    }

    private static func lifecycle(
        for reason: PlaybackAnalytics.TerminalReason
    ) -> PlaybackAnalytics.Lifecycle {
        switch reason {
        case .completed:
            .completed
        case .backgrounded:
            .backgrounded
        case .failed, .crashed:
            .failed
        case .abandonedBeforeStart, .cancelled, .incomplete, .interrupted, .unknown:
            .cancelled
        }
    }

    private static func attribution(
        from path: HLSFeedTelemetry.Path,
        preserving attribution: Attribution
    ) -> Attribution {
        let mediaKind: MediaKind
        switch path.mediaKind {
        case .videoOnDemand:
            mediaKind = .videoOnDemand
        case .live:
            mediaKind = .live
        case .stitched:
            mediaKind = .stitched
        }
        return Attribution(
            reuse: path.reuse == .warm ? .warm : .cold,
            intent: path.intent == .focused ? .focused : .predicted,
            mediaKind: mediaKind,
            networkLeg: attribution.networkLeg,
            cacheTier: attribution.cacheTier
        )
    }

    private static func dimensions(
        from attribution: Attribution
    ) -> PlaybackAnalytics.Dimensions {
        guard let catalog = try? PlaybackAnalytics.DimensionCatalog(allowedValues: [
            "cache_reuse": ["cold", "warm"],
            "feed_intent": ["focused", "predicted"],
            "media_kind": ["vod", "live", "stitched"],
            "network_leg": ["none", "player_proxy", "proxy_origin"],
            "cache_tier": ["none", "memory", "disk", "origin"],
        ]),
        let dimensions = try? catalog.dimensions(from: [
            "cache_reuse": attribution.reuse.rawValue,
            "feed_intent": attribution.intent.rawValue,
            "media_kind": attribution.mediaKind.rawValue,
            "network_leg": attribution.networkLeg.rawValue,
            "cache_tier": attribution.cacheTier.rawValue,
        ]) else {
            return .empty
        }
        return dimensions
    }

    private static func measurements(
        _ values: [(String, Double, PlaybackAnalytics.MeasurementUnit)]
    ) -> [PlaybackAnalytics.Measurement] {
        values.compactMap { name, value, unit in
            guard value.isFinite,
                  let name = try? PlaybackAnalytics.MeasurementName(name)
            else { return nil }
            return try? PlaybackAnalytics.Measurement(
                name: name,
                value: max(0, value),
                unit: unit
            )
        }
    }

    private static func total<Key: Hashable>(_ values: [Key: UInt64]) -> UInt64 {
        values.values.reduce(0, saturatingAdd)
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }

    private static func delta(_ current: Int, _ previous: Int) -> Int {
        current >= previous ? current - previous : current
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? .max : value.partialValue
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? .max : value.partialValue
    }
}
