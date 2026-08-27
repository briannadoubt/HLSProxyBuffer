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
        return view
    }

    public func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.player = player.player
        context.coordinator.update(
            player: player,
            url: url,
            configuration: configuration,
            autoplay: autoplay
        )
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public static func dismantleUIView(_ uiView: PlayerView, coordinator: Coordinator) {
        coordinator.cancel()
        uiView.player = nil
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

    @MainActor
    public final class Coordinator {
        private var task: Task<Void, Never>?
        private var url: URL?
        private var configuration: ProxyPlayerConfiguration?
        private var autoplay = false

        func update(
            player: ProxyHLSPlayer,
            url: URL,
            configuration: ProxyPlayerConfiguration,
            autoplay: Bool
        ) {
            guard self.url != url || self.configuration != configuration || self.autoplay != autoplay else { return }
            self.url = url
            self.configuration = configuration
            self.autoplay = autoplay
            task?.cancel()
            task = Task { @MainActor [weak player] in
                guard let player else { return }
                await player.updateConfiguration(configuration)
                guard !Task.isCancelled else { return }
                await player.load(from: url, quality: configuration.qualityPolicy)
                guard !Task.isCancelled else { return }
                if autoplay { player.play() }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
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
        view.player = player.player
        return view
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player.player
        context.coordinator.update(
            player: player,
            url: url,
            configuration: configuration,
            autoplay: autoplay
        )
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.cancel()
        nsView.player = nil
    }

    @MainActor
    public final class Coordinator {
        private var task: Task<Void, Never>?
        private var url: URL?
        private var configuration: ProxyPlayerConfiguration?
        private var autoplay = false

        func update(
            player: ProxyHLSPlayer,
            url: URL,
            configuration: ProxyPlayerConfiguration,
            autoplay: Bool
        ) {
            guard self.url != url || self.configuration != configuration || self.autoplay != autoplay else { return }
            self.url = url
            self.configuration = configuration
            self.autoplay = autoplay
            task?.cancel()
            task = Task { @MainActor [weak player] in
                guard let player else { return }
                await player.updateConfiguration(configuration)
                guard !Task.isCancelled else { return }
                await player.load(from: url, quality: configuration.qualityPolicy)
                guard !Task.isCancelled else { return }
                if autoplay { player.play() }
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}
#endif
#endif
