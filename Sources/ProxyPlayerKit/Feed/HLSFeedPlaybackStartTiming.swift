import Foundation

/// One in-flight focus owns three clock readings, never a navigation history.
/// Missing or non-monotonic observations yield no diagnostic stage sample; the
/// existing end-to-end playback measurement is recorded independently.
struct HLSFeedPlaybackStartTiming {
    let requestedAt: Duration
    var activationBeganAt: Duration?
    var playInvokedAt: Duration?

    func sample(nativePlayingAt: Duration, confirmedAt: Duration) -> HLSFeedTelemetry.Event.Payload? {
        guard let activationBeganAt, let playInvokedAt,
              requestedAt <= activationBeganAt,
              activationBeganAt <= playInvokedAt,
              playInvokedAt <= nativePlayingAt,
              nativePlayingAt <= confirmedAt else { return nil }
        return .playbackStartStages(
            beforeActivation: Self.seconds(activationBeganAt - requestedAt),
            activationWork: Self.seconds(playInvokedAt - activationBeganAt),
            nativeStart: Self.seconds(nativePlayingAt - playInvokedAt),
            callbackDelivery: Self.seconds(confirmedAt - nativePlayingAt)
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
