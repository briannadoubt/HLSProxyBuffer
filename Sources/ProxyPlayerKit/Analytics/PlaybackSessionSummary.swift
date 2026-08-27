import Foundation

/// Reconciles the bounded event contract into one terminal fleet summary.
///
/// The accumulator retains only scalar totals, peaks, and gauges. It never
/// keeps event history, media identifiers, URLs, or error text. A value can be
/// finished exactly once, making duplicate terminal summaries an explicit
/// programming error.
public struct PlaybackSessionSummarizer: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case correlationMismatch
        case inconsistentClockAnchor
        case timestampBeforeStart
        case alreadyFinished
    }

    public let correlation: PlaybackAnalytics.Correlation
    public let startedAt: PlaybackAnalytics.Timestamp
    public private(set) var recordedEventCount: UInt64 = 0
    public private(set) var isFinished = false

    private var lastTimestamp: PlaybackAnalytics.Timestamp
    private var firstFrameLatency: Double?
    private var observedCompletion = false
    private var startupDuration: Double?
    private var reportedWatchDuration: Double?
    private var stallCount = 0.0
    private var stallDuration = 0.0
    private var reportedStallDuration = 0.0
    private var bitrateTotal = 0.0
    private var bitrateSampleCount: UInt64 = 0
    private var peakBitrate: Double?
    private var variantSwitchCount = 0.0
    private var recoverableErrorCount = 0.0
    private var fatalErrorCount = 0.0
    private var cacheHitCount = 0.0
    private var cacheMissCount = 0.0
    private var originBytes = 0.0
    private var originBytesAvoided = 0.0
    private var explicitCancellationCount = 0.0
    private var acknowledgedCancellationCount = 0.0
    private var lateCancellationCount = 0.0
    private var failedCancellationCount = 0.0
    private var wastedBytes = 0.0
    private var handoffAttemptCount = 0.0
    private var handoffReadyCount = 0.0
    private var handoffSuccessCount = 0.0
    private var liveEdgeDistance: Double?
    private var stitchedBoundarySuccessCount = 0.0
    private var stitchedBoundaryFailureCount = 0.0
    private var peakMemoryResidentBytes: Double?
    private var peakDiskResidentBytes: Double?
    private var peakPlayerPoolOccupancy: Double?
    private var peakProxyPoolOccupancy: Double?

    public init(
        correlation: PlaybackAnalytics.Correlation,
        startedAt: PlaybackAnalytics.Timestamp
    ) {
        self.correlation = correlation
        self.startedAt = startedAt
        lastTimestamp = startedAt
    }

    /// Reconciles one sanitized event. Snapshot-style AVFoundation summaries
    /// merge counters by maximum so they do not double count earlier deltas.
    public mutating func record(_ event: PlaybackAnalytics.Event) throws {
        guard !isFinished else { throw Error.alreadyFinished }
        guard event.correlation == correlation else { throw Error.correlationMismatch }
        guard event.timestamp.anchor == startedAt.anchor else {
            throw Error.inconsistentClockAnchor
        }
        guard event.timestamp.elapsedNanoseconds >= startedAt.elapsedNanoseconds else {
            throw Error.timestampBeforeStart
        }

        if event.timestamp.elapsedNanoseconds >= lastTimestamp.elapsedNanoseconds {
            lastTimestamp = event.timestamp
        }
        recordedEventCount = Self.saturatingAdd(recordedEventCount, 1)
        let snapshotStyle = event.lifecycle == .summaryEmitted
        if event.lifecycle == .playbackStarted, firstFrameLatency == nil {
            firstFrameLatency = max(
                0,
                Self.seconds(from: event.timestamp) - Self.seconds(from: startedAt)
            )
        }
        if event.lifecycle == .completed {
            observedCompletion = true
        }

        for measurement in event.measurements {
            let value = max(0, measurement.value)
            switch (measurement.name.encodedValue, measurement.unit) {
            case ("first_frame_latency", .seconds):
                if firstFrameLatency == nil { firstFrameLatency = value }
            case ("startup_duration", .seconds):
                startupDuration = Self.maximum(startupDuration, value)
            case ("watch_duration", .seconds):
                reportedWatchDuration = Self.maximum(reportedWatchDuration, value)
            case ("stall_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &stallCount)
            case ("stall_duration", .seconds):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &stallDuration)
            case ("stall_recovery_duration", .seconds):
                reportedStallDuration = max(reportedStallDuration, value)
            case ("average_bitrate", .bitsPerSecond):
                bitrateTotal = Self.saturatingAdd(bitrateTotal, value)
                bitrateSampleCount = Self.saturatingAdd(bitrateSampleCount, 1)
            case ("peak_bitrate", .bitsPerSecond):
                peakBitrate = Self.maximum(peakBitrate, value)
            case ("variant_switch_count", .count),
                 ("variant_switch_success_count", .count),
                 ("variant_switch_failure_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &variantSwitchCount)
            case ("recoverable_error_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &recoverableErrorCount)
            case ("fatal_error_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &fatalErrorCount)
            case ("completion_count", .count):
                observedCompletion = observedCompletion || value > 0
            case ("cache_hit_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &cacheHitCount)
            case ("cache_miss_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &cacheMissCount)
            case ("origin_bytes", .bytes):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &originBytes)
            case ("origin_bytes_avoided", .bytes):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &originBytesAvoided)
            case ("cancellation_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &explicitCancellationCount)
            case ("cancellation_acknowledged_count", .count):
                Self.merge(
                    value,
                    snapshotStyle: snapshotStyle,
                    into: &acknowledgedCancellationCount
                )
            case ("cancellation_late_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &lateCancellationCount)
            case ("cancellation_failure_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &failedCancellationCount)
            case ("wasted_bytes", .bytes):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &wastedBytes)
            case ("handoff_attempt_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &handoffAttemptCount)
            case ("handoff_ready_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &handoffReadyCount)
            case ("handoff_success_count", .count):
                Self.merge(value, snapshotStyle: snapshotStyle, into: &handoffSuccessCount)
            case ("live_edge_distance", .seconds):
                liveEdgeDistance = value
            case ("stitched_boundary_success_count", .count):
                Self.merge(
                    value,
                    snapshotStyle: snapshotStyle,
                    into: &stitchedBoundarySuccessCount
                )
            case ("stitched_boundary_failure_count", .count):
                Self.merge(
                    value,
                    snapshotStyle: snapshotStyle,
                    into: &stitchedBoundaryFailureCount
                )
            case ("memory_resident_bytes", .bytes):
                peakMemoryResidentBytes = Self.maximum(peakMemoryResidentBytes, value)
            case ("disk_resident_bytes", .bytes):
                peakDiskResidentBytes = Self.maximum(peakDiskResidentBytes, value)
            case ("player_pool_occupancy", .count):
                peakPlayerPoolOccupancy = Self.maximum(peakPlayerPoolOccupancy, value)
            case ("proxy_pool_occupancy", .count):
                peakProxyPoolOccupancy = Self.maximum(peakProxyPoolOccupancy, value)
            default:
                break
            }
        }
    }

    /// Produces the sole terminal summary for this accumulator.
    public mutating func finish(
        reason: PlaybackAnalytics.TerminalReason,
        endedAt: PlaybackAnalytics.Timestamp,
        dimensions: PlaybackAnalytics.Dimensions = .empty
    ) throws -> PlaybackAnalytics.Summary {
        guard !isFinished else { throw Error.alreadyFinished }
        guard endedAt.anchor == startedAt.anchor else {
            throw Error.inconsistentClockAnchor
        }
        guard endedAt.elapsedNanoseconds >= startedAt.elapsedNanoseconds else {
            throw Error.timestampBeforeStart
        }
        isFinished = true

        let end = endedAt.elapsedNanoseconds >= lastTimestamp.elapsedNanoseconds
            ? endedAt
            : lastTimestamp
        let elapsedAfterFirstFrame = firstFrameLatency.map {
            max(0, Self.seconds(from: end) - Self.seconds(from: startedAt) - $0)
        }
        let watchDuration = max(reportedWatchDuration ?? 0, elapsedAfterFirstFrame ?? 0)
        let totalStallDuration = max(stallDuration, reportedStallDuration)
        let rebufferDenominator = Self.saturatingAdd(watchDuration, totalStallDuration)
        let cacheRequestCount = Self.saturatingAdd(cacheHitCount, cacheMissCount)
        let resolvedReason: PlaybackAnalytics.TerminalReason = if observedCompletion {
            switch reason {
            case .cancelled, .incomplete, .interrupted:
                .completed
            default:
                reason
            }
        } else {
            reason
        }
        let categorizedCancellations = Self.saturatingAdd(
            Self.saturatingAdd(acknowledgedCancellationCount, lateCancellationCount),
            failedCancellationCount
        )
        let cancellationCount = max(
            max(explicitCancellationCount, categorizedCancellations),
            resolvedReason == .cancelled ? 1 : 0
        )
        let terminalFatalCount = max(
            fatalErrorCount,
            resolvedReason == .failed || resolvedReason == .crashed ? 1 : 0
        )

        var values: [(String, Double, PlaybackAnalytics.MeasurementUnit)] = [
            ("startup_abandonment_count", firstFrameLatency == nil ? 1 : 0, .count),
            ("watch_duration", watchDuration, .seconds),
            ("completion_count", resolvedReason == .completed ? 1 : 0, .count),
            ("stall_count", stallCount, .count),
            ("stall_duration", totalStallDuration, .seconds),
            ("variant_switch_count", variantSwitchCount, .count),
            ("recoverable_error_count", recoverableErrorCount, .count),
            ("fatal_error_count", terminalFatalCount, .count),
            ("cache_hit_count", cacheHitCount, .count),
            ("cache_miss_count", cacheMissCount, .count),
            ("origin_bytes", originBytes, .bytes),
            ("origin_bytes_avoided", originBytesAvoided, .bytes),
            ("cancellation_count", cancellationCount, .count),
            ("wasted_bytes", wastedBytes, .bytes),
            ("handoff_attempt_count", handoffAttemptCount, .count),
            ("handoff_ready_count", handoffReadyCount, .count),
            ("handoff_success_count", handoffSuccessCount, .count),
            ("stitched_boundary_success_count", stitchedBoundarySuccessCount, .count),
            ("stitched_boundary_failure_count", stitchedBoundaryFailureCount, .count),
        ]
        Self.append(startupDuration, named: "startup_duration", unit: .seconds, to: &values)
        Self.append(firstFrameLatency, named: "first_frame_latency", unit: .seconds, to: &values)
        Self.append(
            rebufferDenominator > 0 ? totalStallDuration / rebufferDenominator : nil,
            named: "rebuffer_ratio",
            unit: .ratio,
            to: &values
        )
        Self.append(
            bitrateSampleCount > 0 ? bitrateTotal / Double(bitrateSampleCount) : nil,
            named: "average_bitrate",
            unit: .bitsPerSecond,
            to: &values
        )
        Self.append(peakBitrate, named: "peak_bitrate", unit: .bitsPerSecond, to: &values)
        Self.append(
            cacheRequestCount > 0 ? cacheHitCount / cacheRequestCount : nil,
            named: "cache_hit_rate",
            unit: .ratio,
            to: &values
        )
        Self.append(
            handoffAttemptCount > 0 ? handoffReadyCount / handoffAttemptCount : nil,
            named: "handoff_readiness_rate",
            unit: .ratio,
            to: &values
        )
        Self.append(
            handoffAttemptCount > 0 ? handoffSuccessCount / handoffAttemptCount : nil,
            named: "handoff_success_rate",
            unit: .ratio,
            to: &values
        )
        Self.append(liveEdgeDistance, named: "live_edge_distance", unit: .seconds, to: &values)
        Self.append(
            peakMemoryResidentBytes,
            named: "peak_memory_resident_bytes",
            unit: .bytes,
            to: &values
        )
        Self.append(
            peakDiskResidentBytes,
            named: "peak_disk_resident_bytes",
            unit: .bytes,
            to: &values
        )
        Self.append(
            peakPlayerPoolOccupancy,
            named: "peak_player_pool_occupancy",
            unit: .count,
            to: &values
        )
        Self.append(
            peakProxyPoolOccupancy,
            named: "peak_proxy_pool_occupancy",
            unit: .count,
            to: &values
        )

        return try PlaybackAnalytics.Summary(
            correlation: correlation,
            startedAt: startedAt,
            endedAt: end,
            terminalReason: resolvedReason,
            dimensions: dimensions,
            measurements: values.map { name, value, unit in
                try PlaybackAnalytics.Measurement(
                    name: .init(name),
                    value: value,
                    unit: unit
                )
            }
        )
    }

    private static func merge(
        _ value: Double,
        snapshotStyle: Bool,
        into total: inout Double
    ) {
        total = snapshotStyle ? max(total, value) : saturatingAdd(total, value)
    }

    private static func maximum(_ current: Double?, _ candidate: Double) -> Double {
        max(current ?? 0, candidate)
    }

    private static func append(
        _ value: Double?,
        named name: String,
        unit: PlaybackAnalytics.MeasurementUnit,
        to values: inout [(String, Double, PlaybackAnalytics.MeasurementUnit)]
    ) {
        guard let value, value.isFinite else { return }
        values.append((name, max(0, value), unit))
    }

    private static func seconds(from timestamp: PlaybackAnalytics.Timestamp) -> Double {
        Double(timestamp.elapsedNanoseconds) / 1_000_000_000
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? .max : value.partialValue
    }

    private static func saturatingAdd(_ lhs: Double, _ rhs: Double) -> Double {
        let result = lhs + rhs
        return result.isFinite ? result : Double.greatestFiniteMagnitude
    }
}
