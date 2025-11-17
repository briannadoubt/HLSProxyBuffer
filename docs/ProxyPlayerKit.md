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

## UIKit / AppKit Bridging

`ProxyPlayerViewController` and `ProxyPlayerNSView` now store their `ProxyHLSPlayer` references with `@Bindable`, so SwiftUI recomputes their representable structs whenever Observation reports a change. This keeps `AVPlayerLayer` instances in sync with `ProxyHLSPlayer.player` while still letting UIKit/AppKit own the view hosting.

## Migration Notes

- Use `@State` + `@Bindable` (or `@Environment(\.proxyPlayer)` if you inject it) instead of `@StateObject`/`@ObservedObject`.
- Derived helpers that should not trigger view invalidations belong in `@ObservationIgnored` members or extensions, as seen in `ProxyHLSPlayer`.
- Combine-based observers no longer fire; rely on Observation-driven updates or the `ProxyPlayerDiagnostics` callbacks for imperative hooks.
- The tvOS/iOS autoplay logic lives in `ProxyVideoAutoplayController`, making it easy to test and reason about stateful playback triggers.

When exposing the player through additional frameworks, mirror this pattern: adopt `@Bindable` if the consumer is a SwiftUI `DynamicProperty`, or call `ObservationTracking` directly if you need imperative callbacks.
