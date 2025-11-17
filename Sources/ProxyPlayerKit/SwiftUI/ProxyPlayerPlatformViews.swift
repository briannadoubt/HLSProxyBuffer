import Foundation
#if canImport(SwiftUI) && canImport(AVKit)
import SwiftUI
import AVKit
import AVFoundation
import Observation

#if canImport(UIKit)
public struct ProxyPlayerViewController: UIViewRepresentable {
    @Bindable private var player: ProxyHLSPlayer
    private let configuration: ProxyPlayerConfiguration
    private let url: URL
    private let autoplay: Bool

    public init(
        player: ProxyHLSPlayer,
        url: URL,
        configuration: ProxyPlayerConfiguration,
        autoplay: Bool = false
    ) {
        self._player = Bindable(wrappedValue: player)
        self.configuration = configuration
        self.url = url
        self.autoplay = autoplay
    }

    public func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.player = player.player
        Task {
            await player.load(from: url, quality: configuration.qualityPolicy)
            if autoplay {
                player.play()
            }
        }
        return view
    }

    public func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.player = player.player
    }

    public typealias UIViewType = PlayerView

    public final class PlayerView: UIView {
        override public static var layerClass: AnyClass { AVPlayerLayer.self }

        public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        public var player: AVPlayer? {
            get { playerLayer.player }
            set { playerLayer.player = newValue }
        }
    }
}
#endif

#if canImport(AppKit)
public struct ProxyPlayerNSView: NSViewRepresentable {
    @Bindable private var player: ProxyHLSPlayer
    private let configuration: ProxyPlayerConfiguration
    private let url: URL
    private let autoplay: Bool

    public init(
        player: ProxyHLSPlayer,
        url: URL,
        configuration: ProxyPlayerConfiguration,
        autoplay: Bool = false
    ) {
        self._player = Bindable(wrappedValue: player)
        self.configuration = configuration
        self.url = url
        self.autoplay = autoplay
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        Task {
            await player.load(from: url, quality: configuration.qualityPolicy)
            if autoplay {
                player.play()
            }
        }
        view.player = player.player
        return view
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player.player
    }
}
#endif
#endif
