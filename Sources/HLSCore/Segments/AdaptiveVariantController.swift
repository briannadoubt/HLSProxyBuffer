import Foundation

public actor AdaptiveVariantController {
    public struct Policy: Sendable, Equatable {
        public var minimumBitrateRatio: Double
        public var maximumBitrateRatio: Double
        public var hysteresisPercent: Double
        public var minimumSwitchInterval: TimeInterval
        public var failureDowngradeThreshold: Int

        public init(
            minimumBitrateRatio: Double = 0.85,
            maximumBitrateRatio: Double = 1.2,
            hysteresisPercent: Double = 10,
            minimumSwitchInterval: TimeInterval = 4,
            failureDowngradeThreshold: Int = 2
        ) {
            self.minimumBitrateRatio = minimumBitrateRatio
            self.maximumBitrateRatio = maximumBitrateRatio
            self.hysteresisPercent = hysteresisPercent
            self.minimumSwitchInterval = minimumSwitchInterval
            self.failureDowngradeThreshold = failureDowngradeThreshold
        }
    }

    public enum Reason: Sendable, Equatable {
        case manualLock
        case insufficientMetrics
        case variantsUnavailable
        case missingBitrate
        case minimumInterval
        case hysteresis
        case throughputIncreased
        case throughputDecreased
        case consecutiveFailures
        case bufferDepleted
        case boundaryReached
    }

    public struct Decision: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            case hold
            case switchVariant
        }

        public let action: Action
        public let targetVariant: VariantPlaylist?
        public let reason: Reason
        public let timestamp: Date

        public init(action: Action, targetVariant: VariantPlaylist?, reason: Reason, timestamp: Date = Date()) {
            self.action = action
            self.targetVariant = targetVariant
            self.reason = reason
            self.timestamp = timestamp
        }
    }

    private var policy: Policy
    private var variants: [VariantPlaylist] = []
    private var consecutiveFailures = 0
    private var lastSwitchDate: Date?
    private var lastDecisionValue: Decision?
    private let logger: Logger
    private var hasEstablishedBufferWindow = false

    public init(policy: Policy = .init(), logger: Logger = DefaultLogger()) {
        self.policy = policy
        self.logger = logger
    }

    public func updatePolicy(_ policy: Policy) {
        self.policy = policy
    }

    public func updateVariants(_ variants: [VariantPlaylist]) {
        self.variants = variants
    }

    public func registerFailure() {
        consecutiveFailures += 1
    }

    public func resetFailures() {
        consecutiveFailures = 0
    }

    public func reset() {
        consecutiveFailures = 0
        lastSwitchDate = nil
        lastDecisionValue = nil
        hasEstablishedBufferWindow = false
    }

    public func latestDecision() -> Decision? {
        lastDecisionValue
    }

    public func evaluate(
        currentVariant: VariantPlaylist?,
        qualityPolicy: HLSRewriteConfiguration.QualityPolicy,
        throughputSample: ThroughputEstimator.Sample?,
        bufferState: BufferState,
        now: Date = Date()
    ) -> Decision {
        if case .locked = qualityPolicy {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .manualLock, timestamp: now))
        }

        guard !variants.isEmpty else {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .variantsUnavailable, timestamp: now))
        }

        guard let currentVariant else {
            return recordDecision(Decision(action: .hold, targetVariant: nil, reason: .variantsUnavailable, timestamp: now))
        }

        guard let currentBitrate = bitrate(for: currentVariant) else {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .missingBitrate, timestamp: now))
        }

        guard let throughputSample, throughputSample.bitsPerSecond > 0 else {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .insufficientMetrics, timestamp: now))
        }

        guard bufferState.playedThroughSequence != nil else {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .boundaryReached, timestamp: now))
        }

        let sorted = sortedVariants()
        guard let currentIndex = sorted.firstIndex(where: { $0.id == currentVariant.id }) else {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .variantsUnavailable, timestamp: now))
        }

        let lowerVariant = lowestVariant(below: currentIndex, in: sorted)
        let higherVariant = highestVariant(above: currentIndex, in: sorted)
        let throughput = throughputSample.bitsPerSecond

        if bufferState.prefetchDepthSeconds > 0.1 || !bufferState.readySequences.isEmpty {
            hasEstablishedBufferWindow = true
        }

        if shouldDowngradeForFailures(), let target = lowerVariant {
            resetFailures()
            return makeSwitchDecision(target: target, reason: .consecutiveFailures, now: now)
        }

        if hasEstablishedBufferWindow,
           bufferState.prefetchDepthSeconds <= 0.1,
           let target = lowerVariant {
            return makeSwitchDecision(target: target, reason: .bufferDepleted, now: now)
        }

        if let target = lowerVariant, shouldDowngrade(currentBitrate: currentBitrate, throughput: throughput) {
            return makeSwitchDecision(target: target, reason: .throughputDecreased, now: now)
        } else if let target = higherVariant, shouldUpgrade(targetBitrate: bitrate(for: target), throughput: throughput) {
            return makeSwitchDecision(target: target, reason: .throughputIncreased, now: now)
        } else if isWithinHysteresis(currentBitrate: currentBitrate, higherVariant: higherVariant, lowerVariant: lowerVariant, throughput: throughput) {
            return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .hysteresis, timestamp: now))
        }

        return recordDecision(Decision(action: .hold, targetVariant: currentVariant, reason: .boundaryReached, timestamp: now))
    }

    private func shouldDowngradeForFailures() -> Bool {
        policy.failureDowngradeThreshold > 0 && consecutiveFailures >= policy.failureDowngradeThreshold
    }

    private func bitrate(for variant: VariantPlaylist) -> Int? {
        variant.attributes.averageBandwidth ?? variant.attributes.bandwidth
    }

    private func sortedVariants() -> [VariantPlaylist] {
        variants.sorted { (bitrate(for: $0) ?? 0) < (bitrate(for: $1) ?? 0) }
    }

    private func lowestVariant(below index: Int, in variants: [VariantPlaylist]) -> VariantPlaylist? {
        guard index > 0 else { return nil }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let candidate = variants[candidateIndex]
            if bitrate(for: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private func highestVariant(above index: Int, in variants: [VariantPlaylist]) -> VariantPlaylist? {
        guard index < variants.count - 1 else { return nil }
        for candidateIndex in (index + 1)..<variants.count {
            let candidate = variants[candidateIndex]
            if bitrate(for: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private func shouldDowngrade(currentBitrate: Int, throughput: Double) -> Bool {
        guard policy.minimumBitrateRatio > 0 else { return false }
        let baseThreshold = Double(currentBitrate) * policy.minimumBitrateRatio
        let hysteresisThreshold = baseThreshold * max(0, 1 - policy.hysteresisPercent / 100)
        if throughput <= hysteresisThreshold {
            return true
        }
        return false
    }

    private func shouldUpgrade(targetBitrate: Int?, throughput: Double) -> Bool {
        guard
            policy.maximumBitrateRatio > 0,
            let targetBitrate
        else { return false }
        let baseThreshold = Double(targetBitrate) * policy.maximumBitrateRatio
        let hysteresisThreshold = baseThreshold * (1 + policy.hysteresisPercent / 100)
        if throughput >= hysteresisThreshold {
            return true
        }
        return false
    }

    private func isWithinHysteresis(
        currentBitrate: Int,
        higherVariant: VariantPlaylist?,
        lowerVariant: VariantPlaylist?,
        throughput: Double
    ) -> Bool {
        let hysteresisValue = policy.hysteresisPercent / 100

        if policy.minimumBitrateRatio > 0, let lowerVariant, let lowerBitrate = bitrate(for: lowerVariant) {
            let baseDown = Double(currentBitrate) * policy.minimumBitrateRatio
            let hysteresisDown = baseDown * max(0, 1 - hysteresisValue)
            if throughput <= baseDown, throughput > hysteresisDown, lowerBitrate < currentBitrate {
                return true
            }
        }

        if policy.maximumBitrateRatio > 0, let higherVariant, let higherBitrate = bitrate(for: higherVariant) {
            let baseUp = Double(higherBitrate) * policy.maximumBitrateRatio
            let hysteresisUp = baseUp * (1 + hysteresisValue)
            if throughput >= baseUp, throughput < hysteresisUp {
                return true
            }
        }

        return false
    }

    private func makeSwitchDecision(target: VariantPlaylist, reason: Reason, now: Date) -> Decision {
        if let lastSwitchDate,
           now.timeIntervalSince(lastSwitchDate) < policy.minimumSwitchInterval {
            return recordDecision(Decision(action: .hold, targetVariant: target, reason: .minimumInterval, timestamp: now))
        }

        lastSwitchDate = now
        let decision = Decision(action: .switchVariant, targetVariant: target, reason: reason, timestamp: now)
        lastDecisionValue = decision
        logger.log("ABR switching to \(target.url.absoluteString) reason=\(reason)", category: .player)
        return decision
    }

    private func recordDecision(_ decision: Decision) -> Decision {
        lastDecisionValue = decision
        return decision
    }
}

extension AdaptiveVariantController.Reason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .manualLock:
            return "manual_lock"
        case .insufficientMetrics:
            return "insufficient_metrics"
        case .variantsUnavailable:
            return "variants_unavailable"
        case .missingBitrate:
            return "missing_bitrate"
        case .minimumInterval:
            return "minimum_interval"
        case .hysteresis:
            return "hysteresis"
        case .throughputIncreased:
            return "throughput_increased"
        case .throughputDecreased:
            return "throughput_decreased"
        case .consecutiveFailures:
            return "failure_downgrade"
        case .bufferDepleted:
            return "buffer_depleted"
        case .boundaryReached:
            return "boundary_reached"
        }
    }
}
