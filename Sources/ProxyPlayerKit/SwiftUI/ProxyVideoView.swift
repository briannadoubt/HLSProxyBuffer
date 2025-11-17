import Foundation
#if canImport(SwiftUI) && canImport(AVKit)
import SwiftUI
import AVKit
import Observation
import HLSCore

public struct ProxyVideoView: View {
    @State private var player: ProxyHLSPlayer
    @State private var autoplayController = ProxyVideoAutoplayController()
    private let remoteURL: URL
    private let configuration: ProxyPlayerConfiguration
    private let qualityOverride: HLSRewriteConfiguration.QualityPolicy?
    private let autoplay: Bool

    public init(
        url: URL,
        configuration: ProxyPlayerConfiguration = .init(),
        qualityOverride: HLSRewriteConfiguration.QualityPolicy? = nil,
        autoplay: Bool = false
    ) {
        _player = State(initialValue: ProxyHLSPlayer(configuration: configuration))
        self.remoteURL = url
        self.configuration = configuration
        self.qualityOverride = qualityOverride
        self.autoplay = autoplay
    }

    public init(
        player: ProxyHLSPlayer,
        url: URL,
        qualityOverride: HLSRewriteConfiguration.QualityPolicy? = nil,
        autoplay: Bool = false
    ) {
        _player = State(initialValue: player)
        self.remoteURL = url
        self.configuration = player.configuration
        self.qualityOverride = qualityOverride
        self.autoplay = autoplay
    }

    public var body: some View {
        @Bindable var bindablePlayer = player
        let statusLabel = statusText(for: bindablePlayer.state)

        VideoPlayer(player: bindablePlayer.player)
            .task(id: remoteURL) {
                let quality = qualityOverride ?? configuration.qualityPolicy
                autoplayController.reset()
                await bindablePlayer.load(from: remoteURL, quality: quality)
            }
            .onChange(of: bindablePlayer.state.status, initial: false) { _, status in
                autoplayController.handleTransition(
                    to: status,
                    autoplay: autoplay,
                    player: bindablePlayer
                )
            }
#if os(tvOS)
            .focusable(true)
            .onPlayPauseCommand {
                if bindablePlayer.state.status == .ready {
                    if bindablePlayer.player?.timeControlStatus == .playing {
                        bindablePlayer.pause()
                    } else {
                        bindablePlayer.play()
                    }
                }
            }
#endif
#if os(visionOS)
            .glassBackgroundEffect()
#endif
            .overlay(alignment: .topLeading) {
                Text(statusLabel)
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
    }


    private func statusText(for state: PlayerState) -> String {
        switch state.status {
        case .idle: return "Idle"
        case .buffering: return "Buffering"
        case .ready: return "Ready (\(String(format: "%.1fs", state.bufferDepthSeconds)))"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}
 
#if DEBUG
#Preview("Proxy video preview (memory buffer)") {
    ProxyVideoView(
        url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!,
        configuration: ProxyPlayerConfiguration(
            bufferPolicy: .init(
                targetBufferSeconds: 8,
                maxPrefetchSegments: 8,
                hideUntilBuffered: false
            ),
            cachePolicy: .init(
                memoryCapacity: 100,
                enableDiskCache: false
            )
        ),
        autoplay: true
    )
    .frame(height: 240)
    .padding()
}
#endif
#endif
