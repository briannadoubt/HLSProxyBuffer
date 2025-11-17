# HLSProxyBuffer

> Deterministic HLS playback with a self-hosted proxy, LL-HLS aware buffering policies, and player surfaces ready for UIKit, SwiftUI, and AppKit.

HLSProxyBuffer rewrites every remote playlist and segment into a localhost-only experience so that AVPlayer consumes content at machine-speed. It exists for teams that want the determinism of a custom caching layer, the observability of a proxy server, and the ergonomics of a modern Swift package.

## Why HLSProxyBuffer

- **Low-latency expertise** – LL-HLS metadata (`#EXT-X-PART`, blocking reload hints, rendition reports) is parsed, rewritten, and cached automatically, keeping playback below a second on mobile and tvOS. Full guidance lives in `docs/LowLatencyHLS.md`.
- **Deterministic ABR & caching** – Throughput estimators, rewrite policies, and LRU caches collaborate inside `HLSCore` so you know exactly when and why variants change.
- **Batteries-included observability** – `/debug/status` and `/metrics` expose buffer depth, LL-HLS readiness, blocking reload state, cache eviction counts, and per-segment timings.
- **Drop-in player surfaces** – `ProxyPlayerKit` provides `ProxyHLSPlayer`, SwiftUI views, and diagnostics hooks so you can wire policies into your UI within minutes.

## Quick Start

```sh
swift build
swift test
```

While iterating on simulator/device behavior, run the bundled CI script:

```sh
./Scripts/run-ci.sh
```

This script executes SwiftPM tests and, when Xcode simulators are available, attempts basic iOS/tvOS builds to ensure the package schemes still compile.

## Code Samples

### SwiftUI + ProxyPlayerKit

```swift
import ProxyPlayerKit
import SwiftUI

struct LowLatencyStreamView: View {
    @StateObject private var player = ProxyHLSPlayer(
        configuration: .init(
            cachePolicy: .init(memoryCapacity: 256 * 1024 * 1024),
            bufferPolicy: .init(targetBufferSeconds: 10, maxPrefetchSegments: 12),
            lowLatencyPolicy: .init(isEnabled: true, targetPartBufferCount: 6, enableBlockingReloads: true)
        )
    )

    private let streamURL = URL(string: "https://example.com/live/playlist.m3u8")!

    var body: some View {
        ProxyVideoView(player: player, url: streamURL, autoplay: true)
            .overlay(alignment: .topLeading) {
                Text("Buffer \(player.state.bufferDepthSeconds, specifier: \"%.1f\")s (\(player.state.qualityDescription))")
                    .font(.caption.monospacedDigit())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
            }
    }
}
```

`ProxyHLSPlayer` encapsulates the manifest fetcher, LL-HLS scheduler, cache, and embedded proxy server. The SwiftUI surface stays declarative, while diagnostics remain opt-in via `ProxyPlayerDiagnostics`.

### Custom Local Proxy server

```swift
import HLSCore
import LocalProxy

let segmentFetcher = HLSSegmentFetcher(validationPolicy: .default)
let cache = HLSSegmentCache(capacity: 512 * 1024 * 1024)
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
print("Proxy ready at \(server.baseURL!)")
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
- **ProxyDebug** contains optional tooling for status dashboards.

Every dependency is injected (URL sessions, schedulers, routers) so units stay testable. See `specs/` and `docs/` for deeper design discussions and reference flows.

## Scaling Into A Blazing-Fast Player

- **Predictable buffering** – Target buffer/part counts, ABR policies, and LL-HLS knobs are configuration structs, so you can tune them per-market or per-device. This keeps startup latency low while avoiding stalls on congested networks.
- **Composable caching** – Memory/disk caches can be swapped or mirrored. The cache catalog knows which segments are safe to evict, enabling multi-hundred-Mbps live events without ballooning memory.
- **Horizontal observability** – Metrics endpoints match Prometheus-style scrapes and are safe to fan out to custom dashboards. With determinisitic key identifiers, you can correlate manifest, DRM, and segment health across fleets.
- **Concurrency aware** – Everything is annotated with `Sendable`, `@MainActor`, and `async/await`, so the library scales across Swift Concurrency domains without races. Background prefetching and main-thread UI updates stay isolated.
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
Scripts/run-ci.sh      # Host + simulator smoke tests
specs/ & docs/         # Reference designs, buffer policies, LL-HLS primer
```

Additional design docs live under `docs/` and `specs/`. The SwiftUI preview (`ProxyVideoView`) can be used as a quick manual demo inside Xcode; there is no standalone app target inside this package.

## Contributing

1. Keep modules decoupled—only `ProxyPlayerKit` should depend on `HLSCore` + `LocalProxy`.
2. Prefer `swift test --filter <Case>` while iterating; run `make test` or `./Scripts/run-ci.sh` before opening a PR.
3. Update `docs/` or `specs/` when behavior changes (buffer policies, public APIs, proxy semantics).
4. Ensure new features expose deterministic logging so they are observable via `/debug/status` and `/metrics`.
