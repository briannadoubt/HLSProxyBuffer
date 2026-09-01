# HLSProxyBuffer

> Automatic, high-performance HLS feeds with bounded prediction, pooled playback, seamless handoff, live/DVR, and standards-compliant stitching.

HLSProxyBuffer turns ordered HLS sources plus framework-independent viewport signals into an automatic playback feed. The engine owns AVPlayer, its loopback proxy, predictive segment work, cancellation, memory/disk reuse, and resource pools. Typed policies cover short-form, paged, continuous/windowed, long-form, live, and offline-first experiences without making an app assemble players or buffers.

## Why HLSProxyBuffer

- **Low-latency HLS** – LL-HLS metadata (`#EXT-X-PART`, preload hints, blocking reloads, delta updates, and rendition reports) is parsed, rewritten, and cached through localhost. Actual glass-to-glass latency still depends on the encoder, origin, player, and configured hold-back. Full guidance lives in `docs/LowLatencyHLS.md`.
- **Deterministic ABR & caching** – Throughput estimators, rewrite policies, and LRU caches collaborate inside `HLSCore` so you know exactly when and why variants change.
- **Batteries-included observability** – `/debug/status` and `/metrics` expose buffer depth, LL-HLS readiness, blocking reload state, cache eviction counts, and per-segment timings.
- **Fleet-safe analytics** – `PlaybackAnalytics` provides versioned `Sendable`/`Codable` events, opaque correlation, monotonic timing, deterministic JSON, and caller dimensions that can only emit reviewed values or `other`. See [`docs/PlaybackAnalytics.md`](docs/PlaybackAnalytics.md).
- **Drop-in player surfaces** – `ProxyPlayerKit` provides `ProxyHLSPlayer`, SwiftUI views, and diagnostics hooks so you can wire policies into your UI within minutes.
- **Automatic feeds** – `HLSFeedEngine` accepts visibility, focus, velocity, and destination predictions; keeps only a bounded working set warm; and hands the engine-owned player to `HLSFeedVideo`.

## Quick Start

Add the package to your `Package.swift` and select the products your app needs:

```swift
dependencies: [
    .package(
        url: "https://github.com/briannadoubt/HLSProxyBuffer.git",
        from: "0.2.0"
    )
]
```

For the high-level player and automatic feed API, depend on the
`HLSProxyBuffer` product and import `ProxyPlayerKit`. `HLSCore` and
`LocalProxy` are also available as focused products for custom pipelines.

```sh
swift build
swift test
```

Launch the self-contained SwiftUI demo on macOS:

```sh
swift run HLSProxyFeedDemo
```

It serves the checked-in fixture pack from loopback, so short-form, paging, continuous scrolling, long-form, live/DVR, offline-first, looping, and stitched playback work without the public internet. See [`docs/AutomaticFeedDemo.md`](docs/AutomaticFeedDemo.md).

While iterating on simulator/device behavior, run the bundled CI script:

```sh
./Scripts/run-ci.sh
```

This script executes SwiftPM tests and, when Xcode simulators are available, attempts basic iOS/tvOS builds to ensure the package schemes still compile.

Run the release-mode proxy microbenchmarks with:

```sh
make benchmark
```

The benchmark exercises memory-cache hits, catalog lookups, and cached segment requests under serial and concurrent load. Treat the numbers as a local regression signal rather than a cross-machine performance contract.

## Code Samples

### Automatic feed

The integration core is one Observation model. The UI reports geometry as `FeedViewportSignal` and renders an engine-owned lease; it never creates an `AVPlayer` or proxy:

```swift
import Observation
import ProxyPlayerKit
import SwiftUI

@MainActor @Observable
final class FeedSession {
    let engine: HLSFeedEngine

    init(items: [FeedPlaybackItem]) throws {
        engine = try HLSFeedEngine(
            items: items,
            policy: .preset(.shortFormFeed)
        )
    }

    func update(_ signal: FeedViewportSignal) async throws {
        try await engine.update(signal)
    }
}

struct FeedCard: View {
    let session: FeedSession
    let itemID: FeedItemID
    var body: some View { HLSFeedVideo(engine: session.engine, itemID: itemID) }
}
```

The demo contains the complete SwiftUI geometry adapter, stable focus/accessibility behavior, live controls, policy switching, and bounded telemetry overlay.

### SwiftUI + ProxyPlayerKit

```swift
import ProxyPlayerKit
import SwiftUI

struct LowLatencyStreamView: View {
    @State private var player = ProxyHLSPlayer(
        configuration: .preset(.lowLatencyLive)
    )

    private let streamURL = URL(string: "https://example.com/live/playlist.m3u8")!

    var body: some View {
        @Bindable var player = player

        ProxyVideoView(player: player, url: streamURL, autoplay: true)
            .overlay(alignment: .topLeading) {
                Text("Buffer \(player.bufferDepthSeconds, specifier: \"%.1f\")s (\(player.qualityDescription))")
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
            }
    }
}
```

`ProxyHLSPlayer` encapsulates the manifest fetcher, LL-HLS scheduler, cache, and embedded proxy server. The SwiftUI surface stays declarative, while diagnostics remain opt-in via `ProxyPlayerDiagnostics`. Because the player is annotated with `@Observable`, store it in `@State` and access it via `@Bindable` to let the Observation graph refresh any SwiftUI view that reads its properties—no `@StateObject` or `ObservableObject` bridging required. See `docs/ProxyPlayerKit.md` for a deeper dive into the Observation-based API and migration tips, and `docs/ConfigurationPresets.md` for validated workload starting points.

### Custom Local Proxy server

```swift
import HLSCore
import LocalProxy

let segmentFetcher = HLSSegmentFetcher(validationPolicy: .default)
let cache = HLSSegmentCache(capacityBytes: 512 * 1024 * 1024)
let scheduler = SegmentPrefetchScheduler(configuration: .init(targetBufferSeconds: 15))
let playlistStore = PlaylistStore()
let segmentCatalog = SegmentCatalog()

let router = ProxyRouter()
router.register(path: "/playlist.m3u8", handler: PlaylistHandler(store: playlistStore).makeHandler())
router.register(path: "/segments/*", handler: SegmentHandler(
    cache: cache,
    catalog: segmentCatalog,
    fetcher: segmentFetcher,
    scheduler: scheduler
).makeHandler())
router.register(path: "/metrics", handler: MetricsHandler(cache: cache, scheduler: scheduler).makeHandler())

let server = ProxyServer(router: router)
try server.start()
if let baseURL = server.baseURL {
    print("Proxy ready at \(baseURL)")
}
```

This snippet exposes playlists and segments over `NWListener`. You can bolt on new router paths (`/debug/status`, `/assets/*`, etc.) as you build custom tooling or embed the server inside a larger application.
Feed the `PlaylistStore` and `SegmentCatalog` with fresh manifests/segments using `HLSManifestFetcher`, `HLSParser`, and `HLSRewriter` so the proxy always serves deterministic, rewritten playlists.

## Architecture

```
Remote HLS → HLSManifestFetcher → HLSParser → HLSRewriter
           → SegmentPrefetchScheduler → HLSSegmentFetcher & Cache
           → LocalProxy (NWListener HTTP server) → AVPlayer via ProxyPlayerKit
```

- **HLSCore** is pure logic: manifest parsing, deterministic rewrites, LRU caches, and the prefetch scheduler that balances parts, segments, and byte-range requests.
- **LocalProxy** is the transport layer: an `NWListener`-backed router that serves rewritten playlists/segments and exposes diagnostics endpoints.
- **ProxyPlayerKit** wires policies into UIKit/SwiftUI/AppKit surfaces, hosts `ProxyHLSPlayer`, and relays state/metrics to your UI.
- **HLSProxyFeedDemo** proves the automatic feed API against deterministic local media without exposing engine internals to the view layer.

Every dependency is injected (URL sessions, schedulers, routers) so units stay testable. See `specs/` and `docs/` for deeper design discussions and reference flows.

## Scaling Into A Blazing-Fast Player

- **Predictable buffering** – Target buffer/part counts, ABR policies, and LL-HLS knobs are configuration structs, so you can tune them per-market or per-device. This keeps startup latency low while avoiding stalls on congested networks.
- **Bounded caching** – Memory and optional disk caches use byte budgets, URL/range-aware identities, mapped disk reads, and LRU eviction so large segments cannot turn an entry-count limit into unbounded memory.
- **Horizontal observability** – Metrics endpoints match Prometheus-style scrapes and are safe to fan out to custom dashboards. With deterministic key identifiers, you can correlate manifest, DRM, and segment health across fleets.
- **Concurrency aware** – Actors isolate asynchronous subsystem state; `@concurrent` keeps manifest work off caller actors; a dedicated executor contains blocking disk I/O; lightweight locks protect tiny synchronous hot-path state; bounded task groups prefetch concurrently; duplicate origin reads are coalesced; and `AsyncStream` state feeds bridge the pipeline to Observation-backed UI.
- **Future-ready roadmap** – The modular split means you can swap the transport (e.g., QUIC) or plug in custom `SegmentPrefetchScheduler` strategies as you chase lower latency and higher throughput.

## Repo Layout

```
Sources/
  HLSCore/            # Parsing, rewrite, cache, scheduler
  LocalProxy/         # HTTP server + handlers
  ProxyPlayerKit/     # Player orchestration + SwiftUI wrappers
  ProxyDebug/         # Diagnostics UIs & helpers
Tests/
  HLSCoreTests/
  LocalProxyTests/
  ProxyPlayerKitTests/
Benchmarks/HLSProxyBenchmarks/ # Release-mode hot-path microbenchmarks
Demo/HLSProxyFeedDemo/         # Runnable automatic SwiftUI feed + local fixtures
Scripts/run-ci.sh      # Host + simulator smoke tests
specs/ & docs/         # Reference designs, buffer policies, LL-HLS primer
```

Additional design docs live under `docs/` and `specs/`. `HLSProxyFeedDemo` is the standalone reference app; `ProxyVideoView` remains useful for a single-stream preview.

See the [0.2.0 release notes](CHANGELOG.md#020---2026-08-31) for migration
guidance from the `0.1.0` prerelease.

## Contributing

1. Keep modules decoupled—only `ProxyPlayerKit` should depend on `HLSCore` + `LocalProxy`.
2. Prefer `swift test --filter <Case>` while iterating; run `make test` or `./Scripts/run-ci.sh` before opening a PR.
3. Update `docs/` or `specs/` when behavior changes (buffer policies, public APIs, proxy semantics).
4. Ensure new features expose deterministic logging so they are observable via `/debug/status` and `/metrics`.
