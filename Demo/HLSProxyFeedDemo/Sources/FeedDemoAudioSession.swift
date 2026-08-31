import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import AVFAudio
#endif

/// Audio-session policy belongs to the host app, never the reusable feed engine.
@MainActor
protocol FeedDemoAudioSessionManaging: AnyObject {
    func setPlaybackActive(_ active: Bool) throws
}

@MainActor
final class FeedDemoAudioSession: FeedDemoAudioSessionManaging {
    private var isActive = false

    func setPlaybackActive(_ active: Bool) throws {
        guard active != isActive else { return }
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        if active {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        isActive = active
    }
}
