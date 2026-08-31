import AVFoundation

/// One prepared output per bounded player lease, sampled only while focused.
/// No pixel buffers or frame histories are retained. This observes decoded
/// availability, not display scan-out.
@MainActor
final class HLSFeedVideoOutputObserver {
    @MainActor
    private final class Resources {
        weak var item: AVPlayerItem?
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        var task: Task<Void, Never>?

        func stop() {
            task?.cancel()
            task = nil
            item?.remove(output)
            item = nil
        }

        // The observer transfers cleanup to the main actor before releasing us.
        deinit {}
    }
    private let resources = Resources()
    private struct Sampling {
        let requestedAt: Duration?
        let clock: FeedCoordinatorClock
        let record: @MainActor (HLSFeedTelemetry.Event.Payload) -> Void
    }
    private var sampling: Sampling?
    private var lastPresentationTime: CMTime?
    private var hasFirstFrame = false

    var isSampling: Bool { resources.task != nil }

    init(item: AVPlayerItem) {
        resources.item = item
        // Configure before preroll, not during a prepared handoff. Rendering
        // remains enabled; paused neighbors retain no sampled image buffers.
        resources.output.suppressesPlayerRendering = false
        item.add(resources.output)
    }

    func isAttached(to item: AVPlayerItem) -> Bool {
        resources.item === item && item.outputs.contains { $0 === resources.output }
    }

    func start(
        requestedAt: Duration?,
        clock: FeedCoordinatorClock,
        record: @escaping @MainActor (HLSFeedTelemetry.Event.Payload) -> Void
    ) {
        pause()
        guard resources.item != nil else { return }
        sampling = Sampling(requestedAt: requestedAt, clock: clock, record: record)
        resources.task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.sample() else { return }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func pause() {
        resources.task?.cancel()
        resources.task = nil
        sampling = nil
        lastPresentationTime = nil
        hasFirstFrame = false
    }

    func stop() {
        pause()
        resources.stop()
    }

    deinit {
        performMainActorCleanup { [resources] in resources.stop() }
    }

    private func sample() -> Duration? {
        guard let item = resources.item, let sampling else { return nil }
        let output = resources.output
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
