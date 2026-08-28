# Automatic HLS Feed Demo

`HLSProxyFeedDemo` is a runnable SwiftUI reference app for the high-level `HLSFeedEngine` API. It demonstrates that an adopter can build a fast video feed without owning an `AVPlayer`, proxy listener, manifest fetcher, segment scheduler, or cache.

Run it on macOS from the package root:

```sh
swift run HLSProxyFeedDemo
```

Opening `Package.swift` in Xcode also exposes the `HLSProxyFeedDemo` scheme for Apple-platform builds. The checked-in `Demo/HLSProxyFeedDemo/HLSProxyFeedDemoApp.xcodeproj` adds a real iOS application and UI-test host. `project.yml` is its XcodeGen source of truth.

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

The app also demonstrates the complete lifecycle boundary. Its stable
Observation model receives aggregate `ScenePhase` changes, silences the engine
while inactive or backgrounded, and resumes only the current focus on return.
An identifier-based SwiftUI app-refresh handler and an iOS-17-compatible
`BGProcessingTask` adapter share one typed scheduler interface. Each consumed
request is resubmitted for a future opportunity, and foreground reconciliation
cancels pending and active obsolete work.

Background execution is opportunistic: iOS may delay or never launch a
submitted request. If it does launch one, the demo offers only the engine's
current direction-aware predictions. The `.shortFormFeed` warming policy limits
that set to two items, one leading segment each, one concurrent preparation,
4 MiB of estimated bytes, and 15 seconds. `NWPathMonitor`, Low Data Mode, Low
Power Mode, cellular policy, cache freshness/validators, and system expiration
are applied before or during admission. No background path creates a player or
retains an audible owner.

Focus is deterministic: the highest visible fraction wins, then distance from viewport center, then catalog order. A focus change advances the navigation generation; geometry updates within the same focus retain the generation. Stable accessibility identifiers include:

- `automatic-feed-viewport`
- `feed-item-<stable item id>`
- `mode-<mode name>`
- `feed-metrics-overlay`
- `live-seek-behind` and `live-jump-to-edge`
- `low-power-toggle`
- `background-warming-disclosure`
- `qualification-ready`, `qualification-next`, and `qualification-finish`
- `qualification-focus`, `qualification-navigation-count`, and
  `qualification-playback-state`
- `qualification-result` and `qualification-report`
- `vertical-network-normal`, `vertical-network-poor`, and
  `vertical-network-offline`
- `vertical-active-item`, `vertical-audible-item`, and
  `vertical-cancellation-count`
- `vertical-memory-pressure`, `vertical-qualification-finish`, and
  `vertical-qualification-report`

These identifiers are the contract used by the release UI qualification. The
vertical controls appear only with `--vertical-qualification-mode`; normal
launches retain the production-shaped feed chrome.

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

Background lifecycle telemetry is separately fixed-cardinality and Codable. It
counts registered, registration-denied, scheduled, admitted, completed,
expired, cancelled, system-denied, policy-denied, and failed events, plus only
bounded high-water candidate/admission counts. Its JSON contains no task
identifiers, item IDs, URLs, application metadata, or error text.

## Verification

`HLSProxyFeedDemoTests` validates that every mode produces a nonempty, uniquely identified local catalog and a valid policy; that each can enter the public engine path; that geometry produces stable focus, velocity, and prediction signals; and that the fixture origin honors byte ranges and validators. Lifecycle tests inject the scheduler, clock, and network environment to cover registration, refresh/processing submission, system denial, resubmission, foreground cancellation, expiration, policy bounds, audio suspension, and sanitized metrics without depending on simulator background scheduling.

The primary `HLSProxyFeedQualification` UI gate launches the actual paged feed
with `--vertical-qualification-mode`. XCUITest performs controlled page swipes,
forward/backward revisit, a poor-network rapid fling and immediate reversal,
offline reuse, recovery to normal networking, memory pressure, and an actual
background/foreground transition. Every settled gesture must converge the
focused, active, and audible owners on one playing item. The final
`vertical_paging_ui` JSON attachment contains fixed-cardinality first-frame,
stall, cache, origin-network, cancellation, handoff, memory/disk, eviction, and
player-pool evidence. `Scripts/run-ci.sh` exports and validates that attachment
as `hls-feed-vertical-ui-qualification.json`; a missing or failing report fails
CI.

The same scheme separately launches `--qualification-mode`, warms every
short-form item, then drives 100 rapid accessibility-owned focus changes. This
button harness remains a lower-level throughput/resource fixture. It requires
the requested and active item to match, the final platform player to be
playing, predicted-warm first-frame p95 to remain at or below 500 ms, obsolete
work to drain inside 250 ms, configured memory/disk/player bounds to hold, and
managed post-warmup memory growth to stay within 1 MiB.

Simulator backgrounding proves lifecycle reconciliation but not background-task
scheduling: iOS decides whether and when `BGAppRefreshTask` or
`BGProcessingTask` launches. Device runs are still required for energy, thermal,
radio, decoder, and real scheduler qualification. The deterministic injected
lifecycle and network tests cover those decisions in CI without claiming that a
simulator models them.

The host qualification complements that UI run with 532 standard trace
observations, a separate 500-transition engine ownership/teardown test,
production-backend readiness and cache-reuse timing, and explicit VOD, live,
and stitched source coverage. Run the complete local gate with:

```sh
make ci
```

Set `HLS_CI_ARTIFACT_DIR` to select the output directory. Otherwise the script
writes JSON reports and the UI result bundle under `ci-artifacts/`. Hosted CI
also runs Thread Sanitizer and a Release warnings-as-errors build, then uploads
the evidence even when a qualification fails.
