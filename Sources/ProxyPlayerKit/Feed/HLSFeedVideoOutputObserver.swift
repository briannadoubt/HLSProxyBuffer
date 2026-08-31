import AVFoundation

/// One lease-owned output, active only while focused. No pixel buffers or frame
/// histories are retained. This observes decoded availability, not display scan-out.
@MainActor
final class HLSFeedVideoOutputObserver {
    private weak var item: AVPlayerItem?
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ])
    private let requestedAt: Duration?
    private let clock: FeedCoordinatorClock
    private let record: @MainActor (HLSFeedTelemetry.Event.Payload) -> Void
    private var task: Task<Void, Never>?
    private var lastPresentationTime: CMTime?
    private var hasFirstFrame = false

    init(
        item: AVPlayerItem,
        requestedAt: Duration?,
        clock: FeedCoordinatorClock,
        record: @escaping @MainActor (HLSFeedTelemetry.Event.Payload) -> Void
    ) {
        self.item = item
        self.requestedAt = requestedAt
        self.clock = clock
        self.record = record
        // Do not replace/suppress AVPlayerLayer rendering to obtain telemetry.
        output.suppressesPlayerRendering = false
        item.add(output)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.sample() else { return }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        item?.remove(output)
        item = nil
    }

    isolated deinit { stop() }

    private func sample() -> Duration? {
        guard let item else { return nil }
        let time = item.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time) {
            var presentationTime = CMTime.invalid
            if let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentationTime),
               CVPixelBufferGetWidth(pixel) > 0, CVPixelBufferGetHeight(pixel) > 0,
               presentationTime.isNumeric {
                let advanced = lastPresentationTime.map { presentationTime > $0 } ?? false
                let latency = requestedAt.map { requestedAt in
                    let elapsed = clock.now() - requestedAt
                    return max(0, Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18)
                }
                record(.decodedVideo(firstFrameLatency: hasFirstFrame ? nil : latency,
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
