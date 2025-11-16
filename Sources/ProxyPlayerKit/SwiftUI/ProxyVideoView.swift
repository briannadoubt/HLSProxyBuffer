import Foundation
#if canImport(SwiftUI) && canImport(AVKit)
import SwiftUI
import AVKit
import Combine
import HLSCore

public struct ProxyVideoView: View {
    @StateObject private var player: ProxyHLSPlayer
    private let remoteURL: URL
    private let configuration: ProxyPlayerConfiguration
    private let qualityOverride: HLSRewriteConfiguration.QualityPolicy?
    private let autoplay: Bool
    @State private var didAutoPlay = false

    public init(
        url: URL,
        configuration: ProxyPlayerConfiguration = .init(),
        qualityOverride: HLSRewriteConfiguration.QualityPolicy? = nil,
        autoplay: Bool = false
    ) {
        _player = StateObject(wrappedValue: ProxyHLSPlayer(configuration: configuration))
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
        _player = StateObject(wrappedValue: player)
        self.remoteURL = url
        self.configuration = player.configuration
        self.qualityOverride = qualityOverride
        self.autoplay = autoplay
    }

    public var body: some View {
        VideoPlayer(player: player.player)
            .task(id: remoteURL) {
                let quality = qualityOverride ?? configuration.qualityPolicy
                didAutoPlay = false
                await player.load(from: remoteURL, quality: quality)
            }
            .onChange(of: player.state.status) { status in
                guard autoplay, status == .ready, !didAutoPlay else { return }
                didAutoPlay = true
                player.play()
            }
#if os(tvOS)
            .focusable(true)
            .onPlayPauseCommand {
                if player.state.status == .ready {
                    if player.player?.timeControlStatus == .playing {
                        player.pause()
                    } else {
                        player.play()
                    }
                }
            }
#endif
#if os(visionOS)
            .glassBackgroundEffect()
#endif
            .overlay(alignment: .topLeading) {
                Text(statusText)
                    .font(.caption)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
    }


    private var statusText: String {
        switch player.state.status {
        case .idle: return "Idle"
        case .buffering: return "Buffering"
        case .ready: return "Ready (\(String(format: "%.1fs", player.state.bufferDepthSeconds)))"
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
//    .modifier(PreviewTickLogger())
    .frame(height: 240)
    .padding()
}

private struct PreviewTickLogger: ViewModifier {
    private let startDate = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content.onReceive(timer) { now in
            let elapsed = now.timeIntervalSince(startDate)
            print("[ProxyPlayerKit][PREVIEW] tick +\(String(format: "%.1f", elapsed))s")
        }
    }
}
#endif
#endif

