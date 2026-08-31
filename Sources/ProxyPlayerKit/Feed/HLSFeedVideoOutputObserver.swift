import AVFoundation

/// One prepared output per bounded player lease, sampled only while focused.
/// No pixel buffers or frame histories are retained. This observes decoded
/// availability, not display scan-out.
@MainActor
final class HLSFeedVideoOutputObserver {
    private weak var item: AVPlayerItem?
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    private struct Sampling {
        let requestedAt: Duration?
        let clock: FeedCoordinatorClock
        let record: @MainActor (HLSFeedTelemetry.Event.Payload) -> Void
    }
    private var sampling: Sampling?
    private var task: Task<Void, Never>?
    private var lastPresentationTime: CMTime?
    private var hasFirstFrame = false

    var isSampling: Bool { task != nil }

    init(item: AVPlayerItem) {
        self.item = item
        // Configure before preroll, not during a prepared handoff. Rendering
        // remains enabled; paused neighbors retain no sampled image buffers.
        output.suppressesPlayerRendering = false
        item.add(output)
    }

    func isAttached(to item: AVPlayerItem) -> Bool {
        self.item === item && item.outputs.contains { $0 === output }
    }

    func start(
        requestedAt: Duration?,
        clock: FeedCoordinatorClock,
        record: @escaping @MainActor (HLSFeedTelemetry.Event.Payload) -> Void
    ) {
        pause()
        guard item != nil else { return }
        sampling = Sampling(requestedAt: requestedAt, clock: clock, record: record)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.sample() else { return }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        sampling = nil
        lastPresentationTime = nil
        hasFirstFrame = false
    }

    func stop() {
        pause()
        item?.remove(output)
        item = nil
    }

    isolated deinit { stop() }

    private func sample() -> Duration? {
        guard let item, let sampling else { return nil }
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time) {
            var presentationTime = CMTime.invalid
            if let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentationTime),
               CVPixelBufferGetWidth(pixel) > 0, CVPixelBufferGetHeight(pixel) > 0,
               presentationTime.isNumeric {
                let advanced = lastPresentationTime.map { presentationTime > $0 } ?? false
                let latency = sampling.requestedAt.map { requestedAt in
                    let elapsed = sampling.clock.now() - requestedAt
                    return max(0, Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18)
                }
                sampling.record(.decodedVideo(firstFrameLatency: hasFirstFrame ? nil : latency,
                                     frames: 1, advancingFrames: advanced ? 1 : 0))
                lastPresentationTime = presentationTime
                hasFirstFrame = true
            }
        }
        // Fast first-image observation, then ten aggregate samples/second. There
        // is at most one focused sampler, regardless of working-set size.
        return hasFirstFrame ? .milliseconds(100) : .milliseconds(16)
    }
}
