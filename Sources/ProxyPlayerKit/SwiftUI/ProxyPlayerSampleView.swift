import Foundation
#if canImport(SwiftUI) && canImport(AVKit)
import SwiftUI
import AVKit
import Observation

public struct ProxyPlayerSampleView: View {
    @State private var player = ProxyHLSPlayer()
    @State private var urlString = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8"
    @State private var configuration = ProxyPlayerConfiguration()

    public init() {}

    public var body: some View {
        @Bindable var bindablePlayer = player

        VStack(spacing: 16) {
            TextField("Remote HLS URL", text: $urlString)
#if os(tvOS)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
#else
                .textFieldStyle(.roundedBorder)
#endif

            Toggle(
                "Hide segments until buffered",
                isOn: Binding(
                    get: { configuration.bufferPolicy.hideUntilBuffered },
                    set: { newValue in
                        configuration.bufferPolicy.hideUntilBuffered = newValue
                        Task { await bindablePlayer.updateConfiguration(configuration) }
                    }
                )
            )

            VideoPlayer(player: bindablePlayer.player)
                .frame(minHeight: 220)
                .task(id: urlString) {
                    guard let url = URL(string: urlString) else { return }
                    await bindablePlayer.load(from: url, quality: configuration.qualityPolicy)
                }

            HStack {
                Text("Buffer Depth: \(String(format: "%.1f", bindablePlayer.state.bufferDepthSeconds))s")
                Spacer()
                Text("Status: \(bindablePlayer.state.statusDescription)")
            }
            .font(.caption)
        }
        .padding()
    }
}

private extension PlayerState {
    var statusDescription: String {
        switch status {
        case .idle: return "Idle"
        case .buffering: return "Buffering"
        case .ready: return "Ready"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}
#endif
