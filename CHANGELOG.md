# Changelog

HLSProxyBuffer follows [Semantic Versioning](https://semver.org/). Because the
package is still below 1.0, minor releases may include source-breaking API
improvements. Swift Package Manager resolves the package version from Git tags;
there is no separate runtime version constant to keep in sync.

## 0.2.0 - 2026-08-31

`0.2.0` is the first production-oriented, non-prerelease HLSProxyBuffer release.
It evolves the original Observation-backed player into a complete automatic HLS
feed engine, while preserving focused `HLSCore`, `LocalProxy`, and single-player
integration surfaces.

### Highlights

- Added `HLSFeedEngine`, an Observation-native automatic feed runtime that owns
  bounded prediction, player/proxy pooling, focus handoff, cancellation, cache
  reuse, looping, live streams, and compatible stitched clips.
- Added `HLSFeedVideo` for rendering engine-owned leases from SwiftUI without
  allocating or coordinating `AVPlayer` instances in each row.
- Added typed feed presets for short-form, paged, continuous/windowed,
  long-form, live, and offline-first experiences.
- Added live-edge and DVR state plus safe `jumpToLive()` and
  `seek(secondsBehindLiveEdge:)` controls.
- Added validated multi-clip playback for compatible finite HLS media playlists.
- Added fleet-safe playback analytics: a versioned bounded event contract,
  correlation, native AVFoundation metrics, session summaries, exporters,
  backpressure-aware delivery, privacy controls, and an in-demo inspector.
- Added a self-contained SwiftUI feed demo backed by checked-in synthetic and
  real audiovisual HLS fixtures.

### Performance and reliability

- Moved manifest work away from caller actors, isolated blocking disk I/O,
  bounded concurrent prefetch, coalesced duplicate origin reads, reused
  validated manifests, and added release-mode hot-path benchmarks.
- Added byte-budgeted memory and disk caches with namespace-aware expiration,
  mapped disk reads, deterministic eviction telemetry, and cache continuity
  through feed navigation, offline reuse, and memory pressure.
- Added cancellation-aware segment retry with capped exponential jitter,
  `Retry-After` support, explicit transient classification, and shared
  single-flight ownership.
- Hardened the localhost HTTP pipeline with incremental binary-safe parsing,
  bounded request/body handling, persistent connections, GET/HEAD and byte-range
  correctness, sequenced writes, and frozen routes after startup.
- Stabilized player teardown, stale-completion rejection, transient preroll
  recovery, background/foreground transitions, silent retirement, and focused
  audio ownership across rapid feed navigation.
- Kept successful preroll as the feed-readiness gate while leaving the final
  playback transition to AVPlayer's normal stall-minimizing path; real warm
  handoffs and foreground recovery retain decoded-frame qualification.
- Added explicit 500 ms release-reference and 1000 ms shared-runner warm-start
  timing profiles, plus 250 ms and 500 ms observed cancellation-liveness ceilings
  respectively. Qualification artifacts record the active profile while decoded
  frames, ownership, cancellation outcomes, cache, and resource gates stay fixed;
  deterministic coordinator stress continues to enforce 250 ms cancellation.
- Added bounded streaming and feed telemetry for latency, stalls, cache behavior,
  cancellation, handoff success, origin traffic, and resource-pool occupancy.

### HLS and player capabilities

- Added LL-HLS parts, preload hints, blocking reloads, delta updates, rendition
  reports, and standards-compliant rewrites through the local proxy.
- Added configurable origin networking, structured privacy-aware logging,
  playback-rate control, adaptive variants, and validated workload presets.
- Added Prometheus-style `/metrics` and JSON `/debug/status` diagnostics.
- Fixed audio/subtitle rendition parsing without a URI and preserved response
  representation length for body-free HEAD responses.

### Migration from 0.1.0

- The package now requires Swift 6.2 and targets iOS 17, macOS 14,
  Mac Catalyst 17, tvOS 17, and visionOS 1 or newer.
- Continue storing `ProxyHLSPlayer` with `@State` and expose a local `@Bindable`
  value in SwiftUI. For imperative observation, use `stateUpdates()` or
  `ProxyPlayerDiagnostics`; Combine observation is not provided.
- New feeds should prefer `HLSFeedEngine`. `FeedBufferController` remains
  available for existing caller-owned player integrations.
- The SwiftPM product is named `HLSProxyBuffer`, while the high-level module is
  imported as `ProxyPlayerKit`.
- Review custom `ProxyPlayerConfiguration` values against the new typed presets,
  network policy, cache policy, and retry policy before production rollout.

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

    var body: some View {
        HLSFeedVideo(engine: session.engine, itemID: itemID)
    }
}
```

### Release qualification

The release gate covers the full SwiftPM suite, Release warnings-as-errors,
Address Sanitizer analytics qualification, Thread Sanitizer, deterministic
report-contract checks, explicit native audiovisual decode/cache scenarios,
five iOS UI qualification scenarios, and the Release tvOS package suite. See
[`docs/FeedQualification.md`](docs/FeedQualification.md) and
[`docs/real-audiovisual-qualification.md`](docs/real-audiovisual-qualification.md)
for the evidence contract and thresholds.

**Full changelog:**
[`0.1.0...0.2.0`](https://github.com/briannadoubt/HLSProxyBuffer/compare/0.1.0...0.2.0)

## 0.1.0 - 2025-11-16

Prerelease that adopted Swift Observation in `ProxyPlayerKit`.
