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

## Live edge and DVR

Live manifests publish `player.livePlayback` through the same Observation model
and as `PlayerState.livePlayback` on the bounded state stream. The typed state
contains the current media-sequence window, duration, PDT wall-clock range,
discontinuity information, recommended server hold-back, live-edge distance,
and whether the window is live-only, DVR-seekable, or invalid. It is `nil` for
VOD and stitched timelines.

```swift
await player.load(from: liveURL)

if case .dvr(let maximum)? = player.livePlayback?.seekability {
    try await player.seek(secondsBehindLiveEdge: min(30, maximum))
}

// Seeks to HOLD-BACK/PART-HOLD-BACK, not an unsafe zero-latency position.
try await player.jumpToLive()
```

Both controls are generation checked, cancel superseded AVPlayer seeks, and
return `LivePlaybackControlError` for VOD, invalid distances, unavailable
ranges, out-of-window requests, or rejected seeks. Callers never translate
playlist sequences, partial segments, or AVFoundation time ranges themselves.

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

New feed integrations should use `HLSFeedEngine`. It composes predictive
preparation, one bounded shared cache, reusable player/proxy sessions, focus
handoff, looping, stitched sources, and live/DVR controls behind a single
Observation-native API:

```swift
let engine = try HLSFeedEngine(items: items, policy: .shortFormFeed)

for await signal in viewportSignals {
    try await engine.update(signal)
}

HLSFeedVideo(engine: engine, itemID: item.id)
```

`HLSFeedVideo` only renders the engine-owned warm/focused lease. Adopters do not
allocate `AVPlayer`, construct proxy URLs, register buffer observers, or manage
cache and scheduler lifetimes. `engine.snapshot` participates in Observation;
`engine.updates()` provides the same bounded newest-only state to imperative
consumers. Use `engine.setPlaybackRate(_:for:)`, `jumpToLive(for:)`, and
`seek(secondsBehindLiveEdge:for:)` for typed controls, then `await engine.stop()`
when the feed session ends.

Feed quality and resource budgets are available without registering a logging
callback or retaining per-item history:

```swift
let current = engine.telemetry.snapshot

for await event in engine.telemetry.events() {
    consume(event) // bounded newest-event delivery
}

let stressArtifact = try engine.telemetry.machineReadableSummary()
```

The Observation snapshot and deterministic JSON include readiness latency,
stall duration, cache hit rate and origin bytes avoided, cancellation latency
and outcome, handoff readiness/success, current and maximum memory/disk bytes,
and player/proxy pool occupancy. Aggregates use a fixed 12-path matrix for
cold/warm × focused/predicted × VOD/live/stitched. Histograms, subscriber count,
and each subscriber's event buffer are all capped. Slow consumers drop their
oldest pending event and can detect the loss through `droppedEventCount`;
additional consumers beyond the configured cap are rejected and counted.
Instruments receives matching signposts for lifecycle and resource correlation.

The engine accepts ordinary VOD/live streams and
`.compatibleClips([ProxyPlaybackClip])`. The legacy untyped `.clips([URL])`
source remains preparation-only because it lacks the decoder compatibility
facts required to install one safe stitched player timeline.

### Legacy caller-owned controller

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

The automatic `FeedCoordinator` validates `.live` sources with the same
`HLSLiveTimeline` model and carries the resulting `HLSLiveWindow` in
`FeedPreparedItem`. The `.live` policy prepares the newest segments, keeps disk
reuse disabled, and retains the coordinator's existing concurrency and
cancellation bounds during rapid focus changes.

`FeedBufferController` remains source compatible, but its explicit player
registration model is intended for existing integrations. `HLSFeedEngine` is
the default for new feeds.

## UIKit / AppKit Bridging

`ProxyPlayerViewController` and `ProxyPlayerNSView` now store their `ProxyHLSPlayer` references with `@Bindable`, so SwiftUI recomputes their representable structs whenever Observation reports a change. This keeps `AVPlayerLayer` instances in sync with `ProxyHLSPlayer.player` while still letting UIKit/AppKit own the view hosting.

## Migration Notes

- Use `@State` + `@Bindable` (or `@Environment(\.proxyPlayer)` if you inject it) instead of `@StateObject`/`@ObservedObject`.
- Derived helpers that should not trigger view invalidations belong in `@ObservationIgnored` members or extensions, as seen in `ProxyHLSPlayer`.
- Combine-based observers no longer fire; rely on Observation, `stateUpdates()`, or `ProxyPlayerDiagnostics` for imperative hooks.
- The tvOS/iOS autoplay logic lives in `ProxyVideoAutoplayController`, making it easy to test and reason about stateful playback triggers.

When exposing the player through additional frameworks, mirror this pattern: adopt `@Bindable` if the consumer is a SwiftUI `DynamicProperty`, or call `ObservationTracking` directly if you need imperative callbacks.
