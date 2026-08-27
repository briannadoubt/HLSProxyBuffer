# Automatic HLS Feed Demo

`HLSProxyFeedDemo` is a runnable SwiftUI reference app for the high-level `HLSFeedEngine` API. It demonstrates that an adopter can build a fast video feed without owning an `AVPlayer`, proxy listener, manifest fetcher, segment scheduler, or cache.

Run it on macOS from the package root:

```sh
swift run HLSProxyFeedDemo
```

Opening `Package.swift` in Xcode also exposes the `HLSProxyFeedDemo` scheme for Apple-platform builds. The repository CI script compiles that scheme for an available iOS simulator.

## What the demo proves

The mode rail switches the same engine-facing UI among eight experiences:

| Demo mode | Typed engine policy or capability |
| --- | --- |
| Short form | `.shortFormFeed` with a predictive neighbor window |
| Paged | `.pagedFeed` with viewport-sized snap targets |
| Continuous | `.continuousWindowedFeed` with partially visible neighbors |
| Long form | `.longForm` and its larger focused buffer |
| Live + DVR | `.live`, `jumpToLive()`, and typed behind-live-edge seeking |
| Offline first | `.offlineFirst` with memory/disk reuse |
| Looping | `.shortFormFeed` plus the focused-item looping override |
| Stitched | Two compatible fMP4 clips presented as one validated timeline |

Every mode uses repository-generated media under `Demo/HLSProxyFeedDemo/Fixtures`. A model-owned, loopback-only fixture origin supplies playlists, byte ranges, cache validators, and media. `HLSFeedSourceTransportPolicy.allowLoopbackHTTP` permits only `localhost`, IPv4 loopback, or IPv6 loopback cleartext sources; HTTPS remains the production default and remote HTTP is rejected.

## UI boundary

The SwiftUI layer has three responsibilities:

1. Measure card frames in a named viewport coordinate space.
2. Convert visibility, center distance, velocity, focus, and likely destinations into `FeedViewportSignal` values.
3. Render `HLSFeedVideo` for an engine lease.

`FeedDemoModel` owns the engine and local fixture origin. `HLSFeedEngine` owns the bounded preparation coordinator and all playback resources. Changing mode or leaving the view cancels signal subscriptions and awaits engine teardown.

Focus is deterministic: the highest visible fraction wins, then distance from viewport center, then catalog order. A focus change advances the navigation generation; geometry updates within the same focus retain the generation. Stable accessibility identifiers include:

- `automatic-feed-viewport`
- `feed-item-<stable item id>`
- `mode-<mode name>`
- `feed-metrics-overlay`
- `live-seek-behind` and `live-jump-to-edge`
- `low-power-toggle`

These identifiers are the contract used by the rapid-navigation UI qualification ticket.

## Live metrics

The fixed-cardinality overlay reads the same bounded telemetry exposed to production adopters:

- first-frame count and approximate p95 latency, measured from focus request
  until the engine-owned `AVPlayer` first enters its playing time-control state;
- stall count and total duration;
- aggregate cache-hit rate;
- current player occupancy versus policy limit and memory residency;
- acknowledged versus total cancellation count;
- successful handoffs versus destinations already warm at focus request.

Disk residency remains available in the model and telemetry snapshot for detailed inspection. Metrics are aggregated by cold/warm, focused/predicted, and VOD/live/stitched path without retaining item IDs or URLs.

## Verification

`HLSProxyFeedDemoTests` validates that every mode produces a nonempty, uniquely identified local catalog and a valid policy; that each can enter the public engine path; that geometry produces stable focus, velocity, and prediction signals; and that the fixture origin honors byte ranges and validators. Full AVPlayer timing, 100 rapid UI navigations, and sustained resource qualification are intentionally enforced by the subsequent endurance gate rather than hidden inside an unbounded unit test.
