# Automatic HLS Feed Architecture

## North star

`HLSProxyBuffer` should make a high-performance Apple-platform video feed easy
to adopt. An application supplies ordered playable items and framework-neutral
navigation signals. The engine owns manifest and segment work, cache reuse,
proxy lifetimes, player pooling, cancellation, and handoff. A normal adopter
must not construct proxy URLs, coordinate buffers, or maintain an `AVPlayer`
pool.

Standards-compliant clip stitching is a first-class playable source beside VOD
and live streams. It composes with the same planning, budgets, pooling,
telemetry, and demo rather than becoming a separate playback architecture.

## Input contract

`FeedPlaybackItem` is the stable, ordered catalog. Its source is either one VOD
or live HLS URL, or an ordered clip sequence governed by
`specs/clip_stitching.md`. `estimatedPreparationBytes` is a conservative
reservation used before measured segment sizes are available.

`FeedViewportSignal` contains only portable values:

- a monotonically increasing navigation generation;
- the focused item, if focus is settled;
- visible fraction and signed viewport-relative distance;
- signed velocity in viewport lengths per second;
- zero or more destination predictions with confidence; and
- elapsed monotonic time from the session's injected clock.

SwiftUI, UIKit, AppKit, tvOS focus, visionOS, and custom renderers are adapters.
They may derive the signal differently, but the engine never imports their
geometry or scrolling types.

The engine consumes signals in order from an `AsyncSequence`. The producer may
use a newest-value buffer because intermediate scroll samples are not durable
commands. Finishing or cancelling the sequence ends speculative work; an
explicit stop additionally releases focused playback resources. A slower
consumer observes the newest complete signal, never a partially combined one.

## Planning contract

`FeedPlanner` is pure, synchronous, and deterministic. It ranks focused,
visible, explicitly predicted, and velocity-directed neighboring items. Every
accepted plan obeys these invariants:

1. The focused item is first and cannot be silently dropped. If its reservation
   alone exceeds the byte budget, planning returns a typed error.
2. Desired residency never exceeds the item count or estimated byte budget.
3. Newly admitted preparations never exceed the concurrency budget.
4. A signal older than the active generation schedules no preparation or
   cancellation and cannot alter desired residency.
5. Work absent from an accepted replacement plan receives a cancellation
   request whose deadline is at most 100 ms after the injected monotonic time.
6. Stable IDs, rather than array offsets or view identities, own work and cache
   reuse.

HLS-16 will enforce this plan using actors and structured concurrency. Each
result carries its generation; a result may commit only when it still matches
the coordinator's active generation. Cancellation is cooperative but the
coordinator must detach ownership immediately, record late cancellation, and
prevent stale publication.

Run the executable release gate with:

```sh
make benchmark
```

The checked contract is 10,000 representative updates with planning p95 at or
below 1 ms. The benchmark prints the observed p95 and fails when the threshold
is exceeded.

## Target public experience

HLS-17 and HLS-19 will finish an API with this shape (names remain subject to
source-compatible refinement while those tickets are implemented):

```swift
let engine = HLSFeedEngine(
    items: items,
    policy: .shortFormFeed
)

for await signal in feedSignals {
    await engine.update(signal)
}

HLSFeedVideo(engine: engine, itemID: item.id)
```

There is one engine, one typed policy, and signal updates. The playback surface
borrows an engine-owned lease; it does not expose ownership of an `AVPlayer`,
proxy server, cache, or segment scheduler.

The existing `FeedBufferController` remains source compatible while this work
lands, but its caller-owned player registration model is transitional. HLS-17
will move its useful warm/cold behavior behind `HLSFeedEngine`; new integrations
should target the automatic contract rather than manually registering players.

## Policy and capability composition

HLS-14 will expose typed presets for short-form, paged, continuous/windowed,
long-form, live, and offline-first workloads. Focused override groups cover:

- prefetch horizon and leading-segment target;
- item, byte, memory, and disk budgets;
- global and per-origin fetch concurrency plus player-pool occupancy;
- cache expiration and eviction;
- origin network access and request/resource timeouts;
- manifest and segment retry behavior;
- looping; and
- low-power reductions to speculative work.

Existing validated network, retry, telemetry, cache, and player presets remain
the primitives underneath this policy. HLS-10 supplies stitched sources;
HLS-11 supplies live-edge and DVR state. Both flow through HLS-16 planning and
HLS-17 resource ownership.

## Measurement contract

The engine records bounded aggregates and a lossy newest-event stream for:

| Signal | Start | End / value |
| --- | --- | --- |
| First-frame latency | focus generation accepted | first decoded frame displayed |
| Stall | playback was expected to advance | time control resumes or focus changes |
| Cache hit rate | cache lookup | memory, disk, miss, expired, or rejected |
| Memory / disk | residency mutation | bytes and entries after mutation |
| Cancellation | replacement plan requests stop | task finishes or misses deadline |
| Handoff | destination selected | ready lease becomes focused or fails |

Dimensions are bounded workload/source classes (`focused`, `predicted`, `cold`,
`warm`, `vod`, `live`, `stitched`), never arbitrary item or URL cardinality.
HLS-18 adds fixed-memory distributions, counters, Observation snapshots,
`AsyncStream` events with an explicit drop policy, signposts, and a
machine-readable run summary.

## Delivery graph and gates

- HLS-13: this contract, pure model, and 10,000-update planning gate.
- HLS-14: typed presets and overrides.
- HLS-15: repository-owned media, controllable local origin, and replayable
  paging/scroll traces.
- HLS-10: executable stitching contract and real routes.
- HLS-11: live edge, DVR windows, and feed-compatible controls.
- HLS-16: bounded predictive coordination and obsolete-work cancellation.
- HLS-17: pooled resources, seamless handoff, and the simple public API.
- HLS-18: feed-quality and resource instrumentation.
- HLS-19: SwiftUI demo proving every policy and source class.
- HLS-20: release qualification: 500 core transitions, 100 rapid UI
  navigations, p95 readiness/first-frame gates, at least 90% revisit cache hits,
  at least 99% ready handoff success, bounded resource occupancy, and sanitizer,
  release, simulator, and hosted CI evidence.
- HLS-12: retire superseded PR #4 only after every gate above is green.
