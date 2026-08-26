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
                Text("Prefetched \(player.state.bufferDepthSeconds, specifier: "%.1f")s")
            }
    }
}
```

`ProxyVideoView` and `ProxyPlayerSampleView` follow the exact pattern above. The view instantiates the player in `@State`, passes the reference through `@Bindable`, and relies on Observation to invalidate the view whenever `player.player`, `player.state`, or rendition arrays change. There is no `@StateObject`, `ObservableObject`, or `objectWillChange` bridging left in the module.

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

Every time the visible index changes the controller reassigns roles, calls `load`/`play`/`pause`/`stop`, and emits telemetry via `FeedBufferTelemetry`. The sample above shows the integration points: rows register descriptors and the pager reports visibility changes.

## UIKit / AppKit Bridging

`ProxyPlayerViewController` and `ProxyPlayerNSView` now store their `ProxyHLSPlayer` references with `@Bindable`, so SwiftUI recomputes their representable structs whenever Observation reports a change. This keeps `AVPlayerLayer` instances in sync with `ProxyHLSPlayer.player` while still letting UIKit/AppKit own the view hosting.

## Migration Notes

- Use `@State` + `@Bindable` (or `@Environment(\.proxyPlayer)` if you inject it) instead of `@StateObject`/`@ObservedObject`.
- Derived helpers that should not trigger view invalidations belong in `@ObservationIgnored` members or extensions, as seen in `ProxyHLSPlayer`.
- Combine-based observers no longer fire; rely on Observation-driven updates or the `ProxyPlayerDiagnostics` callbacks for imperative hooks.
- The tvOS/iOS autoplay logic lives in `ProxyVideoAutoplayController`, making it easy to test and reason about stateful playback triggers.

When exposing the player through additional frameworks, mirror this pattern: adopt `@Bindable` if the consumer is a SwiftUI `DynamicProperty`, or call `ObservationTracking` directly if you need imperative callbacks.
