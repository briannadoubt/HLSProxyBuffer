import Foundation
import Observation
import os

/// Fixed-memory quality and resource instrumentation for ``HLSFeedEngine``.
///
/// Aggregation cardinality is independent of item and event count. Metrics are
/// partitioned into the twelve possible combinations of cache reuse, feed
/// intent, and media kind. Each path owns three bounded histograms. Event
/// subscribers and their newest-event buffers are capped by ``Configuration``.
@Observable
@MainActor
public final class HLSFeedTelemetry {
    public struct Configuration: Equatable, Sendable {
        public static let defaultLatencyUpperBounds: [TimeInterval] = [
            0.016, 0.033, 0.05, 0.1, 0.25, 0.4, 0.5, 1, 2, 5, 10,
        ]

        public let latencyUpperBounds: [TimeInterval]
        public let eventBufferCapacity: Int
        public let maximumSubscriberCount: Int

        public init(
            latencyUpperBounds: [TimeInterval] = Self.defaultLatencyUpperBounds,
            eventBufferCapacity: Int = 16,
            maximumSubscriberCount: Int = 4
        ) {
            let bounds = Array(Set(latencyUpperBounds.filter { $0.isFinite && $0 > 0 }))
                .sorted()
                .prefix(32)
            self.latencyUpperBounds = bounds.isEmpty
                ? Self.defaultLatencyUpperBounds
                : Array(bounds)
            self.eventBufferCapacity = min(max(1, eventBufferCapacity), 256)
            self.maximumSubscriberCount = min(max(1, maximumSubscriberCount), 8)
        }
    }

    public enum Reuse: String, CaseIterable, Codable, Sendable {
        case cold
        case warm
    }

    public enum Intent: String, CaseIterable, Codable, Sendable {
        case focused
        case predicted
    }

    public enum MediaKind: String, CaseIterable, Codable, Sendable {
        case videoOnDemand
        case live
        case stitched
    }

    /// A fixed-cardinality metric partition. No item IDs or URLs are retained.
    public struct Path: Hashable, Codable, Sendable {
        public let reuse: Reuse
        public let intent: Intent
        public let mediaKind: MediaKind

        public init(reuse: Reuse, intent: Intent, mediaKind: MediaKind) {
            self.reuse = reuse
            self.intent = intent
            self.mediaKind = mediaKind
        }

        public static let all: [Self] = Reuse.allCases.flatMap { reuse in
            Intent.allCases.flatMap { intent in
                MediaKind.allCases.map { mediaKind in
                    Self(reuse: reuse, intent: intent, mediaKind: mediaKind)
                }
            }
        }
    }

    public enum CancellationOutcome: String, CaseIterable, Codable, Sendable {
        case acknowledged
        case late
        case failed
    }

    public struct Distribution: Equatable, Codable, Sendable {
        public let upperBounds: [TimeInterval]
        /// Non-cumulative counts; the final bucket is positive infinity.
        public let bucketCounts: [UInt64]
        public let count: UInt64
        public let sum: TimeInterval
        public let minimum: TimeInterval?
        public let maximum: TimeInterval?

        public var average: TimeInterval? {
            count > 0 ? sum / Double(count) : nil
        }

        public func approximateQuantile(_ quantile: Double) -> TimeInterval? {
            guard count > 0, quantile.isFinite else { return nil }
            let rank = max(
                UInt64(1),
                UInt64(ceil(min(max(quantile, 0), 1) * Double(count)))
            )
            var cumulative: UInt64 = 0
            for (index, bucketCount) in bucketCounts.enumerated() {
                cumulative = Self.saturatingAdd(cumulative, bucketCount)
                guard cumulative >= rank else { continue }
                return index < upperBounds.count ? upperBounds[index] : maximum
            }
            return maximum
        }

        private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? .max : result.partialValue
        }
    }

    public struct PathSnapshot: Equatable, Codable, Sendable {
        public let path: Path
        /// Focus request to the engine-owned AVPlayer first entering its
        /// `.playing` time-control state. Preparation or `play()` invocation
        /// alone does not satisfy this measurement.
        public let firstFrameLatency: Distribution
        public let stallDuration: Distribution
        public let cancellationLatency: Distribution
        public let cacheHitCount: UInt64
        public let cacheMissCount: UInt64
        public let originBytesAvoided: UInt64
        public let cancellationOutcomeCounts: [CancellationOutcome: UInt64]
        /// Focus requests, requests whose destination was warm at submission,
        /// and destinations that subsequently entered platform playback.
        public let handoffAttemptCount: UInt64
        public let handoffReadyCount: UInt64
        public let handoffSuccessCount: UInt64

        public var cacheHitRate: Double? {
            let total = cacheHitCount + cacheMissCount
            return total > 0 ? Double(cacheHitCount) / Double(total) : nil
        }
    }

    public struct ResourceSnapshot: Equatable, Codable, Sendable {
        public let memoryResidentBytes: Int
        public let maximumMemoryResidentBytes: Int
        public let diskResidentBytes: Int
        public let maximumDiskResidentBytes: Int
        public let playerPoolOccupancy: Int
        public let maximumPlayerPoolOccupancy: Int
        public let proxyPoolOccupancy: Int
        public let maximumProxyPoolOccupancy: Int

        public static let empty = Self(
            memoryResidentBytes: 0,
            maximumMemoryResidentBytes: 0,
            diskResidentBytes: 0,
            maximumDiskResidentBytes: 0,
            playerPoolOccupancy: 0,
            maximumPlayerPoolOccupancy: 0,
            proxyPoolOccupancy: 0,
            maximumProxyPoolOccupancy: 0
        )
    }

    /// Exact collection bounds for one telemetry instance.
    public struct StorageBound: Equatable, Codable, Sendable {
        public let pathCount: Int
        public let histogramCount: Int
        public let bucketsPerHistogram: Int
        public let cancellationOutcomesPerPath: Int
        public let maximumSubscriberCount: Int
        public let eventBufferCapacityPerSubscriber: Int

        public var maximumHistogramBucketCount: Int {
            histogramCount * bucketsPerHistogram
        }

        public var maximumCancellationOutcomeCount: Int {
            pathCount * cancellationOutcomesPerPath
        }

        public var maximumBufferedEventCount: Int {
            maximumSubscriberCount * eventBufferCapacityPerSubscriber
        }
    }

    public struct Snapshot: Equatable, Codable, Sendable {
        public let eventCount: UInt64
        public let droppedEventCount: UInt64
        public let rejectedSubscriberCount: UInt64
        public let activeSubscriberCount: Int
        public let resources: ResourceSnapshot
        public let paths: [PathSnapshot]
        public let storageBound: StorageBound

        public func metrics(for path: Path) -> PathSnapshot? {
            paths.first { $0.path == path }
        }

        public var firstFrameCount: UInt64 {
            paths.reduce(0) { Self.saturatingAdd($0, $1.firstFrameLatency.count) }
        }

        public var stallCount: UInt64 {
            paths.reduce(0) { Self.saturatingAdd($0, $1.stallDuration.count) }
        }

        public var cancellationCount: UInt64 {
            paths.reduce(0) { Self.saturatingAdd($0, $1.cancellationLatency.count) }
        }

        public var handoffSuccessCount: UInt64 {
            paths.reduce(0) { Self.saturatingAdd($0, $1.handoffSuccessCount) }
        }

        private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? .max : result.partialValue
        }
    }

    public struct Event: Equatable, Sendable {
        public enum Payload: Equatable, Sendable {
            case firstFrame(latency: TimeInterval)
            case stall(duration: TimeInterval)
            case cache(hits: Int, misses: Int, originBytesAvoided: Int)
            case cancellation(latency: TimeInterval, outcome: CancellationOutcome)
            case handoff(wasReady: Bool, succeeded: Bool)
            case resources(
                memoryBytes: Int,
                diskBytes: Int,
                playerPoolOccupancy: Int,
                proxyPoolOccupancy: Int
            )
        }

        public let path: Path?
        public let payload: Payload

        public init(path: Path? = nil, payload: Payload) {
            self.path = path
            self.payload = payload
        }
    }

    private struct MutableDistribution {
        let upperBounds: [TimeInterval]
        var bucketCounts: [UInt64]
        var count: UInt64 = 0
        var sum: TimeInterval = 0
        var minimum: TimeInterval?
        var maximum: TimeInterval?

        init(upperBounds: [TimeInterval]) {
            self.upperBounds = upperBounds
            self.bucketCounts = Array(repeating: 0, count: upperBounds.count + 1)
        }

        mutating func record(_ value: TimeInterval) {
            let normalized = value.isFinite ? max(0, value) : 0
            let index = upperBounds.firstIndex(where: { normalized <= $0 })
                ?? upperBounds.count
            bucketCounts[index] = HLSFeedTelemetry.saturatingAdd(bucketCounts[index], 1)
            count = HLSFeedTelemetry.saturatingAdd(count, 1)
            sum = sum.addingProduct(1, normalized)
            if !sum.isFinite { sum = .greatestFiniteMagnitude }
            minimum = minimum.map { min($0, normalized) } ?? normalized
            maximum = maximum.map { max($0, normalized) } ?? normalized
        }

        var value: Distribution {
            Distribution(
                upperBounds: upperBounds,
                bucketCounts: bucketCounts,
                count: count,
                sum: sum,
                minimum: minimum,
                maximum: maximum
            )
        }
    }

    private struct MutablePath {
        let path: Path
        var firstFrameLatency: MutableDistribution
        var stallDuration: MutableDistribution
        var cancellationLatency: MutableDistribution
        var cacheHitCount: UInt64 = 0
        var cacheMissCount: UInt64 = 0
        var originBytesAvoided: UInt64 = 0
        var cancellationOutcomeCounts: [CancellationOutcome: UInt64] = [:]
        var handoffAttemptCount: UInt64 = 0
        var handoffReadyCount: UInt64 = 0
        var handoffSuccessCount: UInt64 = 0

        init(path: Path, bounds: [TimeInterval]) {
            self.path = path
            self.firstFrameLatency = MutableDistribution(upperBounds: bounds)
            self.stallDuration = MutableDistribution(upperBounds: bounds)
            self.cancellationLatency = MutableDistribution(upperBounds: bounds)
        }

        var value: PathSnapshot {
            PathSnapshot(
                path: path,
                firstFrameLatency: firstFrameLatency.value,
                stallDuration: stallDuration.value,
                cancellationLatency: cancellationLatency.value,
                cacheHitCount: cacheHitCount,
                cacheMissCount: cacheMissCount,
                originBytesAvoided: originBytesAvoided,
                cancellationOutcomeCounts: cancellationOutcomeCounts,
                handoffAttemptCount: handoffAttemptCount,
                handoffReadyCount: handoffReadyCount,
                handoffSuccessCount: handoffSuccessCount
            )
        }
    }

    public private(set) var snapshot: Snapshot

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let signposter = OSSignposter(
        subsystem: "com.hlsproxybuffer",
        category: "Feed"
    )
    @ObservationIgnored private var mutablePaths: [Path: MutablePath]
    @ObservationIgnored private var resources = ResourceSnapshot.empty
    @ObservationIgnored private var eventCount: UInt64 = 0
    @ObservationIgnored private var droppedEventCount: UInt64 = 0
    @ObservationIgnored private var rejectedSubscriberCount: UInt64 = 0
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.mutablePaths = Dictionary(uniqueKeysWithValues: Path.all.map {
            ($0, MutablePath(path: $0, bounds: configuration.latencyUpperBounds))
        })
        self.snapshot = Snapshot(
            eventCount: 0,
            droppedEventCount: 0,
            rejectedSubscriberCount: 0,
            activeSubscriberCount: 0,
            resources: .empty,
            paths: Path.all.map {
                MutablePath(path: $0, bounds: configuration.latencyUpperBounds).value
            },
            storageBound: Self.storageBound(for: configuration)
        )
    }

    /// Records one typed event and immediately updates the Observation snapshot.
    public func record(_ event: Event) {
        switch event.payload {
        case .firstFrame(let latency):
            mutatePath(for: event) { $0.firstFrameLatency.record(latency) }
            signposter.emitEvent("First Frame")
        case .stall(let duration):
            mutatePath(for: event) { $0.stallDuration.record(duration) }
            signposter.emitEvent("Playback Stall")
        case .cache(let hits, let misses, let avoidedBytes):
            mutatePath(for: event) { path in
                path.cacheHitCount = Self.saturatingAdd(path.cacheHitCount, UInt64(max(0, hits)))
                path.cacheMissCount = Self.saturatingAdd(path.cacheMissCount, UInt64(max(0, misses)))
                path.originBytesAvoided = Self.saturatingAdd(
                    path.originBytesAvoided,
                    UInt64(max(0, avoidedBytes))
                )
            }
        case .cancellation(let latency, let outcome):
            mutatePath(for: event) { path in
                path.cancellationLatency.record(latency)
                path.cancellationOutcomeCounts[outcome] = Self.saturatingAdd(
                    path.cancellationOutcomeCounts[outcome, default: 0],
                    1
                )
            }
            signposter.emitEvent("Cancellation")
        case .handoff(let wasReady, let succeeded):
            mutatePath(for: event) { path in
                path.handoffAttemptCount = Self.saturatingAdd(path.handoffAttemptCount, 1)
                if wasReady {
                    path.handoffReadyCount = Self.saturatingAdd(path.handoffReadyCount, 1)
                }
                if succeeded {
                    path.handoffSuccessCount = Self.saturatingAdd(path.handoffSuccessCount, 1)
                }
            }
            signposter.emitEvent("Feed Handoff")
        case .resources(let memory, let disk, let players, let proxies):
            let normalizedMemory = max(0, memory)
            let normalizedDisk = max(0, disk)
            let normalizedPlayers = max(0, players)
            let normalizedProxies = max(0, proxies)
            resources = ResourceSnapshot(
                memoryResidentBytes: normalizedMemory,
                maximumMemoryResidentBytes: max(
                    resources.maximumMemoryResidentBytes,
                    normalizedMemory
                ),
                diskResidentBytes: normalizedDisk,
                maximumDiskResidentBytes: max(
                    resources.maximumDiskResidentBytes,
                    normalizedDisk
                ),
                playerPoolOccupancy: normalizedPlayers,
                maximumPlayerPoolOccupancy: max(
                    resources.maximumPlayerPoolOccupancy,
                    normalizedPlayers
                ),
                proxyPoolOccupancy: normalizedProxies,
                maximumProxyPoolOccupancy: max(
                    resources.maximumProxyPoolOccupancy,
                    normalizedProxies
                )
            )
            signposter.emitEvent("Resource Sample")
        }

        eventCount = Self.saturatingAdd(eventCount, 1)
        rebuildSnapshot()
        publish(event)
    }

    /// Newest-event streams have an explicit bounded drop policy. If a consumer
    /// cannot keep up, its oldest buffered event is discarded and counted.
    public func events() -> AsyncStream<Event> {
        guard continuations.count < configuration.maximumSubscriberCount else {
            rejectedSubscriberCount = Self.saturatingAdd(rejectedSubscriberCount, 1)
            rebuildSnapshot()
            return AsyncStream { $0.finish() }
        }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(configuration.eventBufferCapacity)) {
            continuation in
            continuations[id] = continuation
            rebuildSnapshot()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeContinuation(id) }
            }
        }
    }

    /// Deterministic JSON suitable for stress artifacts and CI ingestion.
    public func machineReadableSummary() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    public func finish() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        rebuildSnapshot()
    }

    private func mutatePath(for event: Event, _ body: (inout MutablePath) -> Void) {
        guard let path = event.path, var value = mutablePaths[path] else { return }
        body(&value)
        mutablePaths[path] = value
    }

    private func publish(_ event: Event) {
        var terminated: [UUID] = []
        var drops: UInt64 = 0
        for (id, continuation) in continuations {
            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                drops = Self.saturatingAdd(drops, 1)
            case .terminated:
                terminated.append(id)
            @unknown default:
                break
            }
        }
        for id in terminated { continuations.removeValue(forKey: id) }
        if drops > 0 {
            droppedEventCount = Self.saturatingAdd(droppedEventCount, drops)
            rebuildSnapshot()
        }
    }

    private func removeContinuation(_ id: UUID) {
        guard continuations.removeValue(forKey: id) != nil else { return }
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        snapshot = Snapshot(
            eventCount: eventCount,
            droppedEventCount: droppedEventCount,
            rejectedSubscriberCount: rejectedSubscriberCount,
            activeSubscriberCount: continuations.count,
            resources: resources,
            paths: Path.all.compactMap { mutablePaths[$0]?.value },
            storageBound: Self.storageBound(for: configuration)
        )
    }

    private static func storageBound(for configuration: Configuration) -> StorageBound {
        StorageBound(
            pathCount: Path.all.count,
            histogramCount: Path.all.count * 3,
            bucketsPerHistogram: configuration.latencyUpperBounds.count + 1,
            cancellationOutcomesPerPath: CancellationOutcome.allCases.count,
            maximumSubscriberCount: configuration.maximumSubscriberCount,
            eventBufferCapacityPerSubscriber: configuration.eventBufferCapacity
        )
    }

    private nonisolated static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
