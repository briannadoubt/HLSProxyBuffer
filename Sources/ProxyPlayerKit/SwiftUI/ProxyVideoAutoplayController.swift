import Foundation
#if canImport(SwiftUI) && canImport(AVKit)
@MainActor
protocol ProxyVideoAutoplaying: AnyObject {
    func play()
}

@MainActor
struct ProxyVideoAutoplayController {
    private var didAutoPlay = false

    mutating func reset() {
        didAutoPlay = false
    }

    mutating func handleTransition(to status: PlayerState.Status, autoplay: Bool, player: ProxyVideoAutoplaying) {
        guard autoplay, status == .ready, !didAutoPlay else { return }
        didAutoPlay = true
        player.play()
    }
}

extension ProxyHLSPlayer: ProxyVideoAutoplaying {}
#endif
