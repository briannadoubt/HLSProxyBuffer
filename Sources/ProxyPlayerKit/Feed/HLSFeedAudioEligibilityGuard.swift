import AVFoundation
import os

/// Preserves the feed's mute requirement across late AVFoundation property
/// notifications. It never owns an audio session or changes standalone players.
@MainActor
final class HLSFeedAudioEligibilityGuard {
    private weak var player: AVPlayer?
    private var mustRemainMuted = false
    private var muteObservation: NSKeyValueObservation?
    private var volumeObservation: NSKeyValueObservation?
    // KVO may arrive off-main. Coalesce those callbacks into at most one hop.
    private nonisolated let correctionPending = OSAllocatedUnfairLock(initialState: false)

    init(player: AVPlayer) {
        self.player = player
        muteObservation = player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
            self?.nativeAudioChanged()
        }
        volumeObservation = player.observe(\.volume, options: [.new]) { [weak self] _, _ in
            self?.nativeAudioChanged()
        }
    }

    func setMuted(_ muted: Bool) {
        mustRemainMuted = muted
        player?.isMuted = muted
        player?.volume = muted ? 0 : 1
    }

    func stop() {
        muteObservation?.invalidate()
        volumeObservation?.invalidate()
        muteObservation = nil
        volumeObservation = nil
        player = nil
    }

    isolated deinit { stop() }

    private nonisolated func nativeAudioChanged() {
        if Thread.isMainThread {
            // Main-thread KVO must be corrected before other main-actor clients
            // sample the player; do not introduce an unnecessary asynchronous gap.
            MainActor.assumeIsolated { enforceMuteRequirement() }
        } else {
            let shouldSchedule = correctionPending.withLock { pending in
                guard !pending else { return false }
                pending = true
                return true
            }
            guard shouldSchedule else { return }
            let pending = correctionPending
            DispatchQueue.main.async { [weak self] in
                pending.withLock { $0 = false }
                self?.enforceMuteRequirement()
            }
        }
    }

    private func enforceMuteRequirement() {
        guard mustRemainMuted, let player else { return }
        // Check before writing: each setter can synchronously produce another
        // KVO notification. Reassert silence, never auto-start a paused player.
        if !player.isMuted { player.isMuted = true }
        if player.volume != 0 { player.volume = 0 }
    }
}
