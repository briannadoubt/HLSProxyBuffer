# ProxyPlayerKit Observation Model

`ProxyHLSPlayer` is annotated with `@Observable` so every SwiftUI surface can react to buffering, playback, and rendition updates without Combine. The Observation framework requires iOS 17, tvOS 17, macOS 14, or visionOS 1.0, which now match the deployment targets declared in `Package.swift`.

## SwiftUI Integration

Store the player with `@State` (or inject it via `@Environment`) and create a `@Bindable` reference inside your `body` to register dependencies on its properties:

```swift
struct StreamView: View {
    @State private var player = ProxyHLSPlayer()
    private let streamURL: URL

    var body: some View {
        @Bindable var player = player

        ProxyVideoView(player: player, url: streamURL, autoplay: true)
            .overlay(alignment: .bottomLeading) {
                Text("Prefetched \(player.bufferDepthSeconds, specifier: "%.1f")s")
            }
    }
}
```

`ProxyVideoView` and `ProxyPlayerSampleView` follow the same ownership pattern. Frequently changing values (`status`, `bufferDepthSeconds`, and `qualityDescription`) are stored independently, so reading one value does not subscribe a view to unrelated state. There is no `@StateObject`, `ObservableObject`, or `objectWillChange` bridge in the module.

Imperative consumers can use `player.stateUpdates()`. It returns a bounded `AsyncStream<PlayerState>` that immediately yields the current snapshot and then delivers ordered updates without polling. Cancel the consuming task when its owner disappears.

## Playback Rate

`playbackRate` is observable and records the preferred forward-playback speed. Use `setPlaybackRate(_:)` to select a rate; values are clamped to `ProxyHLSPlayer.supportedPlaybackRateRange` (`0.5...2.0`), and `NaN` restores normal speed.

```swift
player.setPlaybackRate(1.5)
player.play()
```

Calling `pause()` sets AVPlayer's effective rate to zero without changing the preference. A later `play()` resumes with the selected rate. The preference also survives manifest reloads and AVPlayer item replacement, and setting it while paused does not start playback.

## Compatible Clip Timelines

Use `ProxyPlaybackClip` when a trusted packager guarantees that multiple finite
media playlists share a decoder configuration. `load(clips:)` validates and
installs one seekable proxy timeline; callers do not create an `AVQueuePlayer`
or manage join buffers.

```swift
let clips = sourceURLs.enumerated().map { index, url in
    ProxyPlaybackClip(
        id: "chapter-\(index)",
        playlistURL: url,
        mediaSignature: signature
    )
}

do {
    try await player.load(clips: clips)
    player.play()
} catch let error as HLSClipStitchingError {
    // The observable player.clipStitchingError contains the same typed reason.
    present(error)
}
```

Direct stitching accepts compatible single-media VOD only. It rejects master
topology, live/LL-HLS state, interstitial metadata, ambiguous program dates,
and incompatible signatures. Encrypted stitched playback uses the memory-only
auxiliary key route; register key bytes by their
`ProxyHLSPlayer.keyIdentifier(forKeyURI:)` value before loading.

## Feed-aware Buffering

TikTok-style feeds want deterministic control over which videos stay warm. `FeedBufferController` coordinates every `ProxyHLSPlayer` in the stack and keeps the visible item playing while the next/previous neighbors retain a shallow buffer. The controller accepts a `FeedBufferPolicy` (max live/VOD neighbors, buffer targets per role, total memory budget, cooldown delay) and `FeedPlayerDescriptor` metadata, including an estimated peak memory cost, so it can prioritize specific rows.

```swift
struct FeedRow: View {
    let descriptor: FeedPlayerDescriptor
    let controller: FeedBufferController

    @State private var player = ProxyHLSPlayer()
    @State private var handle: FeedBufferController.Handle?

    var body: some View {
        @Bindable var player = player

        VideoPlayer(player: player.player)
            .task {
                if let handle {
                    controller.updateDescriptor(for: handle, descriptor: descriptor)
                } else {
                    handle = controller.register(player: player, descriptor: descriptor)
                }
            }
            .onDisappear {
                if let handle {
                    controller.unregister(handle: handle)
                    self.handle = nil
                }
            }
    }
}

struct FeedPager: View {
    @State private var controller = FeedBufferController(policy: .init(maxLiveNeighbors: 2, maxVODNeighbors: 1))
    @State private var visibleIndex = 0

    var body: some View {
        TabView(selection: $visibleIndex) { /* rows omitted */ }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: visibleIndex) { oldValue, newValue in
                let direction: FeedBufferController.ScrollDirection = newValue > oldValue ? .down : .up
                controller.updateVisibleIndex(newValue, direction: direction)
            }
    }
}
```

Every time the visible index changes the controller reassigns roles, serializes configuration before loading, and emits telemetry via `FeedBufferTelemetry`. It consumes each player's state stream rather than polling, retries failed warm loads with capped exponential backoff, and applies each descriptor's memory estimate as a real cache byte cap.

## UIKit / AppKit Bridging

`ProxyPlayerViewController` and `ProxyPlayerNSView` now store their `ProxyHLSPlayer` references with `@Bindable`, so SwiftUI recomputes their representable structs whenever Observation reports a change. This keeps `AVPlayerLayer` instances in sync with `ProxyHLSPlayer.player` while still letting UIKit/AppKit own the view hosting.

## Migration Notes

- Use `@State` + `@Bindable` (or `@Environment(\.proxyPlayer)` if you inject it) instead of `@StateObject`/`@ObservedObject`.
- Derived helpers that should not trigger view invalidations belong in `@ObservationIgnored` members or extensions, as seen in `ProxyHLSPlayer`.
- Combine-based observers no longer fire; rely on Observation, `stateUpdates()`, or `ProxyPlayerDiagnostics` for imperative hooks.
- The tvOS/iOS autoplay logic lives in `ProxyVideoAutoplayController`, making it easy to test and reason about stateful playback triggers.

When exposing the player through additional frameworks, mirror this pattern: adopt `@Bindable` if the consumer is a SwiftUI `DynamicProperty`, or call `ObservationTracking` directly if you need imperative callbacks.
