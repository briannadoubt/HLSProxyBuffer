import Foundation

/// Collects and aggregates metrics for HLS proxy operations
public actor MetricsCollector {
    public struct LatencyHistogram: Sendable {
        public let count: Int
        public let sum: TimeInterval
        public let min: TimeInterval
        public let max: TimeInterval
        public let p50: TimeInterval
        public let p95: TimeInterval
        public let p99: TimeInterval
        public let samples: [TimeInterval]

        public var mean: TimeInterval {
            count > 0 ? sum / Double(count) : 0
        }

        public init(samples: [TimeInterval]) {
            let sorted = samples.sorted()
            self.samples = samples
            self.count = sorted.count
            self.sum = sorted.reduce(0, +)
            self.min = sorted.first ?? 0
            self.max = sorted.last ?? 0
            self.p50 = Self.percentile(sorted, 0.50)
            self.p95 = Self.percentile(sorted, 0.95)
            self.p99 = Self.percentile(sorted, 0.99)
        }

        private static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
            guard !sorted.isEmpty else { return 0 }
            let index = Int(Double(sorted.count - 1) * p)
            return sorted[index]
        }
    }

    public enum MetricType: String, Sendable, CaseIterable {
        case segmentFetch
        case manifestFetch
        case cacheLookup
        case prefetch
        case abrDecision
    }

    public struct VariantSwitchRecord: Sendable {
        public enum Reason: String, Sendable {
            case upgrade
            case downgrade
            case manual
            case initial
        }

        public let fromBitrate: Int?
        public let toBitrate: Int
        public let reason: Reason
        public let timestamp: Date
    }

    public struct LiveEdgeMetrics: Sendable {
        public let distanceFromEdge: TimeInterval
        public let edgeSequence: Int
        public let currentSequence: Int
        public let timestamp: Date
    }

    public struct NetworkMetrics: Sendable {
        public let bytesReceived: Int
        public let bytesSent: Int
        public let requestCount: Int
        public let errorCount: Int
        public let interface: String?
        public let connectionType: String?
    }

    private var latencySamples: [MetricType: [TimeInterval]] = [:]
    private var variantSwitches: [VariantSwitchRecord] = []
    private var liveEdgeHistory: [LiveEdgeMetrics] = []
    private var networkMetrics = NetworkMetrics(
        bytesReceived: 0, bytesSent: 0, requestCount: 0, errorCount: 0, interface: nil, connectionType: nil
    )
    private let maxSamplesPerType: Int
    private let maxHistoryEntries: Int

    public init(maxSamplesPerType: Int = 1000, maxHistoryEntries: Int = 100) {
        self.maxSamplesPerType = maxSamplesPerType
        self.maxHistoryEntries = maxHistoryEntries
    }

    // MARK: - Latency Recording

    public func recordLatency(_ duration: TimeInterval, type: MetricType) {
        var samples = latencySamples[type] ?? []
        samples.append(duration)
        if samples.count > maxSamplesPerType {
            samples.removeFirst(samples.count - maxSamplesPerType)
        }
        latencySamples[type] = samples
    }

    public func latencyHistogram(for type: MetricType) -> LatencyHistogram {
        LatencyHistogram(samples: latencySamples[type] ?? [])
    }

    public func allLatencyHistograms() -> [MetricType: LatencyHistogram] {
        var result: [MetricType: LatencyHistogram] = [:]
        for type in MetricType.allCases {
            result[type] = latencyHistogram(for: type)
        }
        return result
    }

    // MARK: - Variant Switch Tracking

    public func recordVariantSwitch(
        fromBitrate: Int?,
        toBitrate: Int,
        reason: VariantSwitchRecord.Reason
    ) {
        let record = VariantSwitchRecord(
            fromBitrate: fromBitrate,
            toBitrate: toBitrate,
            reason: reason,
            timestamp: Date()
        )
        variantSwitches.append(record)
        if variantSwitches.count > maxHistoryEntries {
            variantSwitches.removeFirst()
        }
    }

    public func variantSwitchHistory() -> [VariantSwitchRecord] {
        variantSwitches
    }

    public func variantSwitchCounts() -> [VariantSwitchRecord.Reason: Int] {
        var counts: [VariantSwitchRecord.Reason: Int] = [:]
        for record in variantSwitches {
            counts[record.reason, default: 0] += 1
        }
        return counts
    }

    // MARK: - Live Edge Tracking

    public func recordLiveEdge(distanceFromEdge: TimeInterval, edgeSequence: Int, currentSequence: Int) {
        let metrics = LiveEdgeMetrics(
            distanceFromEdge: distanceFromEdge,
            edgeSequence: edgeSequence,
            currentSequence: currentSequence,
            timestamp: Date()
        )
        liveEdgeHistory.append(metrics)
        if liveEdgeHistory.count > maxHistoryEntries {
            liveEdgeHistory.removeFirst()
        }
    }

    public func liveEdgeMetrics() -> LiveEdgeMetrics? {
        liveEdgeHistory.last
    }

    public func averageLiveEdgeDistance() -> TimeInterval {
        guard !liveEdgeHistory.isEmpty else { return 0 }
        return liveEdgeHistory.reduce(0) { $0 + $1.distanceFromEdge } / Double(liveEdgeHistory.count)
    }

    // MARK: - Network Metrics

    public func recordNetworkActivity(bytesReceived: Int = 0, bytesSent: Int = 0, isError: Bool = false) {
        networkMetrics = NetworkMetrics(
            bytesReceived: networkMetrics.bytesReceived + bytesReceived,
            bytesSent: networkMetrics.bytesSent + bytesSent,
            requestCount: networkMetrics.requestCount + 1,
            errorCount: networkMetrics.errorCount + (isError ? 1 : 0),
            interface: networkMetrics.interface,
            connectionType: networkMetrics.connectionType
        )
    }

    public func updateNetworkInterface(interface: String?, connectionType: String?) {
        networkMetrics = NetworkMetrics(
            bytesReceived: networkMetrics.bytesReceived,
            bytesSent: networkMetrics.bytesSent,
            requestCount: networkMetrics.requestCount,
            errorCount: networkMetrics.errorCount,
            interface: interface,
            connectionType: connectionType
        )
    }

    public func currentNetworkMetrics() -> NetworkMetrics {
        networkMetrics
    }

    // MARK: - Reset

    public func reset() {
        latencySamples.removeAll()
        variantSwitches.removeAll()
        liveEdgeHistory.removeAll()
        networkMetrics = NetworkMetrics(
            bytesReceived: 0, bytesSent: 0, requestCount: 0, errorCount: 0, interface: nil, connectionType: nil
        )
    }

    // MARK: - JSON Export

    public func exportJSON() -> String {
        var result: [String: Any] = [:]

        // Latency histograms
        var histograms: [String: [String: Any]] = [:]
        for type in MetricType.allCases {
            let h = latencyHistogram(for: type)
            histograms[type.rawValue] = [
                "count": h.count,
                "sum_ms": h.sum * 1000,
                "min_ms": h.min * 1000,
                "max_ms": h.max * 1000,
                "mean_ms": h.mean * 1000,
                "p50_ms": h.p50 * 1000,
                "p95_ms": h.p95 * 1000,
                "p99_ms": h.p99 * 1000
            ]
        }
        result["latency_histograms"] = histograms

        // Variant switches
        result["variant_switch_counts"] = variantSwitchCounts().mapKeys { $0.rawValue }

        // Live edge
        if let edge = liveEdgeMetrics() {
            result["live_edge"] = [
                "distance_seconds": edge.distanceFromEdge,
                "edge_sequence": edge.edgeSequence,
                "current_sequence": edge.currentSequence
            ]
        }
        result["average_live_edge_distance_seconds"] = averageLiveEdgeDistance()

        // Network
        result["network"] = [
            "bytes_received": networkMetrics.bytesReceived,
            "bytes_sent": networkMetrics.bytesSent,
            "request_count": networkMetrics.requestCount,
            "error_count": networkMetrics.errorCount,
            "interface": networkMetrics.interface ?? NSNull(),
            "connection_type": networkMetrics.connectionType ?? NSNull()
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        var result: [T: Value] = [:]
        for (key, value) in self {
            result[transform(key)] = value
        }
        return result
    }
}
