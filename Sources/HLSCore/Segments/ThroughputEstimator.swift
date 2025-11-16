import Foundation

public actor ThroughputEstimator {
    public struct Configuration: Sendable, Equatable {
        public var window: Int

        public init(window: Int = 5) {
            self.window = max(1, window)
        }
    }

    public struct Sample: Sendable, Equatable {
        public let bitsPerSecond: Double
        public let lastSampleDate: Date

        public init(bitsPerSecond: Double, lastSampleDate: Date) {
            self.bitsPerSecond = bitsPerSecond
            self.lastSampleDate = lastSampleDate
        }
    }

    private var configuration: Configuration
    private var averageBitsPerSecond: Double?
    private var lastSampleDate: Date?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public func ingest(_ metrics: HLSSegmentFetcher.FetchMetrics, at timestamp: Date = Date()) {
        guard metrics.duration > 0 else { return }
        let rawBitsPerSecond = Double(metrics.byteCount) * 8.0 / metrics.duration
        let alpha = 2.0 / (Double(configuration.window) + 1.0)

        if let current = averageBitsPerSecond {
            averageBitsPerSecond = alpha * rawBitsPerSecond + (1 - alpha) * current
        } else {
            averageBitsPerSecond = rawBitsPerSecond
        }
        lastSampleDate = timestamp
    }

    public func reset() {
        averageBitsPerSecond = nil
        lastSampleDate = nil
    }

    public func sample() -> Sample? {
        guard
            let bitsPerSecond = averageBitsPerSecond,
            let lastSampleDate
        else { return nil }
        return Sample(bitsPerSecond: bitsPerSecond, lastSampleDate: lastSampleDate)
    }
}
