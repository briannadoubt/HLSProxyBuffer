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
2. Desired residency is one atomic, ordered working set centered on focus.
   The short-form preset defaults to the current item plus two items in each
   direction. Typed ahead/behind bounds clamp the set at collection edges and
   exclude even visible or predicted destinations outside the window.
3. Desired residency never exceeds the item count or estimated byte budget.
   Newly started preparations never exceed the independent concurrency budget;
   lowering concurrency does not reveal the target window piecemeal.
4. A signal older than the active generation schedules no preparation or
   cancellation and cannot alter desired residency.
5. Work absent from an accepted replacement plan receives a cancellation
   request whose deadline is at most 100 ms after the injected monotonic time.
6. Stable IDs, rather than array offsets or view identities, own work and cache
   reuse.

Below the typed directional velocity threshold, neighbors are ranked
symmetrically from nearest to farthest. Directional movement prefers the side
of travel, and a typed fast-fling threshold exhausts that side before the
opposite side. Explicit predictions and visibility remain deterministic and
deduplicated within the same hard window. A direction reversal therefore
publishes one replacement target and cancellation set; late work from its
predecessor still cannot commit into the new generation.

`FeedCoordinator` enforces the plan as the UI- and player-independent runtime
boundary. The public actor owns the current generation, bounded admission,
structured tasks, cancellation accounting, readiness reuse, and a
newest-snapshot `AsyncStream`. Each result carries its generation and policy
revision and may commit only while both remain current. A new generation first
cancels obsolete work; cancellation-pending tasks continue to occupy their
preparation slots until they acknowledge cancellation, so a rapid reversal can
never create a temporary task-budget spike. The injected monotonic clock
records acknowledgement latency and the 100 ms contract without wall-clock
test sleeps.

`HLSFeedPreparationBackend` is the production preparation boundary. It resolves
VOD, live, master/variant, and compatible clip-sequence manifests, selects the
startup quality profile, and fetches only the leading resources permitted by
the coordinator. Manifest, initialization-map, and segment lookups share one
memory/disk cache. Encryption and DRM key bytes never enter that disk-backed
cache; stitched loads use the existing memory-only auxiliary key route. All
cacheable misses pass through one
cancellation-aware global/per-origin limiter and the validated manifest and
segment retry policies. Live streams prepare the newest permitted suffix;
VOD and stitched sources prepare from their leading edge. A
`.compatibleClips([ProxyPlaybackClip])` source resolves every declared media
playlist, validates the complete compatibility contract, and only then admits
leading stitched resources under the coordinator's segment budget.

## Implemented stitched playback path

`HLSClipStitcher` is the deterministic core boundary. It accepts only finite,
single-media VOD inputs with matching trusted signatures; renumbers their
segments; inserts join discontinuities; preserves byte ranges, initialization
maps, encryption state, and program dates; and materializes sequence-derived
AES-128 IVs before renumbering. Live/LL-HLS, topology, codec, ad/interstitial,
and ambiguous-date failures are typed.

`ProxyHLSPlayer.load(clips:)` fetches and validates every manifest before it
changes a catalog, cache, scheduler, proxy playlist, or player item. The
resulting timeline uses the ordinary loopback master, media-playlist, wildcard
resource, and memory-only key routes. A failed replacement clears the
superseded `AVPlayerItem` and exposes `clipStitchingError` through Observation.
No `AVQueuePlayer` or caller-owned proxy state is required.

Readiness is reusable across navigation generations, but reused values are
rebased to the active generation before publication. Replaced item IDs retain
readiness only when their complete source and planning identity are unchanged.
Policy and low-power changes invalidate admitted work by policy revision,
reconfigure owned networking/cache primitives, and replan the last viewport
observation under the new hard caps.

Run the executable release gate with:

```sh
make benchmark
```

The checked contract is 10,000 representative updates with planning p95 at or
below 1 ms. The benchmark prints the observed p95 and fails when the threshold
is exceeded.

## Public feed experience

`HLSFeedEngine` is the owning runtime boundary. A complete integration has one
engine, one typed policy, viewport-signal updates, and engine-backed video
surfaces:

```swift
let engine = try HLSFeedEngine(
    items: items,
    policy: .shortFormFeed
)

for await signal in feedSignals {
    try await engine.update(signal)
}

HLSFeedVideo(engine: engine, itemID: item.id)

// When the owning feed session ends:
await engine.stop()
```

`HLSFeedVideo` subscribes to bounded engine snapshots and attaches only to a
warm or focused lease. It never creates, loads, plays, pauses, or destroys an
`AVPlayer`. The engine automatically pauses speculative sessions, starts the
ready focused destination, preserves the destination's existing player item at
handoff, and detaches recycled leases from their surfaces.

The repository demo launches directly into a full-height vertical feed. On
current OS releases it uses paged scroll targets, bound scroll position, and a
coarsened `onScrollGeometryChange` sample to move the engine's bounded working
set. Its iOS 17 compatibility path projects the same UI-independent signal from
preference-key geometry, so policy and playback ownership do not fork by OS.
Changing source modes gives the scroller a new stable identity, atomically
resetting focus instead of carrying an obsolete page position into a new
catalog. Page, focused-item, and playback accessibility values make real swipe,
forward/backward, and direction-reversal behavior observable to UI tests. The
button-driven qualification view remains available only through its explicit
launch argument as a lower-level 100-navigation performance fixture.

Release UI qualification drives that same vertical pager with real XCUITest
gestures. A test-only overlay changes the loopback fixture origin between
normal, bandwidth-limited, and offline states, forwards memory pressure through
`HLSFeedEngine.handleMemoryPressure()`, and publishes only aggregate ownership
and telemetry values. It never bypasses the viewport-signal adapter or borrows
an engine player. The attached `vertical_paging_ui` report has fixed scenario
and eviction cardinality and excludes item IDs, URLs, paths, headers, and error
text. CI extracts the report from the xcresult bundle and fails closed if it is
absent or does not pass.

Audio ownership is stricter than surface attachment. Every newly allocated or
recycled player is muted before loading or preroll. An accepted focus change
first mutes and pauses the old owner, then unmutes a destination only after its
lease is warm and still matches the current navigation generation. A destination
that is not ready therefore creates a deliberately silent gap instead of letting
stale audio continue; a late preparation completion cannot steal audio after a
fling or direction reversal. `setPlaybackSuspended(_:)` gives lifecycle adapters
one engine-owned background/foreground hook: suspension immediately removes the
audio owner while retaining the bounded warm working set, and resumption starts
only the still-current prepared focus.

`HLSFeedEngineSnapshot` is `Equatable` and fixed-size under the player-pool
limit. It reports target, active, and audible focus, per-lease audibility,
lifecycle suspension, failures, current and high-water player/audio occupancy,
active loads, ordered-loop destination requests, and discarded stale
completions. Observation consumers can read `engine.snapshot`;
imperative consumers use the newest-only `engine.updates()` stream. Playback
rate and live/DVR controls are addressed through the engine, so even imperative
adopters do not borrow player ownership.

The engine creates one shared, policy-bounded memory/disk cache for predictive
preparation and every pooled `ProxyHLSPlayer`. Pooled players preserve that
shared cache when their proxy, scheduler, observer, and `AVPlayerItem` state is
recycled. A generation-scoped lease has exactly one slot owner; stale load
completion cannot publish after reassignment. Off-window grace tasks,
preparation tasks, load tasks, state streams, playback-end observers, proxy
listeners, and player items are cancelled and awaited by `stop()`.

Disk entries retain their canonical URL/range identity, insertion/access age,
ETag, Last-Modified value, and bounded freshness deadline across engine
instances. Fresh playlist, initialization-map, and segment bytes are served
without an origin request on a warm-disk launch. An expired entry remains
available only to the internal conditional-request path: a 304 refreshes its
age and reuses the exact bytes with a zero-byte origin response, while a 200
atomically replaces the entry. Expired or absent work is never served as a
synthetic offline success. Validator sidecars contain no credentials, request
headers, or unbounded dimensions.

`await engine.handleMemoryPressure()` is the single public pressure hook. It
drops memory residency atomically, leaves valid disk entries intact, and blocks
already-started disk reads from repopulating RAM during that pressure response.
Platform lifecycle adapters forward their supported memory warning to this
method; applications still do not own the cache. Fixed-cardinality metrics
report current entries/bytes, memory and disk byte high-water marks, and exact
byte-limit, entry-limit, pressure, and expiration removal reasons. Deterministic
tests cover cross-instance reload, revalidation, offline warm hit/miss, poor
network continuation, and byte/entry LRU enforcement.

The existing `FeedBufferController` remains source compatible while this work
lands, but its caller-owned player registration model is transitional. New
integrations should target `HLSFeedEngine` rather than manually registering
players.

## Opportunistic background warming

`HLSFeedBackgroundWarmer` is the player-free engine boundary for work that the
system chooses to run in the background. A platform adapter provides ordered
predictions, cache-freshness facts, current network cost/constrained state,
Low Power Mode, and the execution time still available. The validated
`HLSFeedBackgroundWarmingPolicy` independently caps admitted items, leading
segments, estimated bytes, concurrent preparations, and elapsed time. The
short-form default warms at most two items, one leading segment per item, one
preparation at a time, and 4 MiB of planning reservations.

Production `HLSFeedEngine` instances create the warmer against their existing
persistent cache and expose it through one adopter-facing call:

```swift
let result = try await engine.warmInBackground(request)
```

No AVPlayer, proxy, fetcher, or cache object crosses that API. Engine policy
updates reconfigure the background preparation path before committing, and
`engine.stop()` cancels an active warming batch along with foreground work.

Fresh cache entries with sufficient validity remaining are skipped. Stale,
near-expiry, absent, and unknown entries may use the canonical manifest and
segment preparation path, including conditional validation and the same
bounded disk cache. Offline, cellular, constrained, expensive, and Low Power
Mode conditions are denied unless their explicit policy allows admission.
Expiration and caller cancellation propagate through structured tasks; bytes
completed before cancellation remain present in the aggregate report. A second
invocation is denied while one is active, so system callbacks cannot create an
unbounded warming fleet.

Scheduling stays outside this UI-independent actor. The iOS demo registers an
identifier-based SwiftUI app-refresh task and an iOS-17-compatible
`BGProcessingTask` launch handler before application launch completes. A typed,
injectable adapter submits both request forms, replaces consumed requests for a
future opportunity, and cancels obsolete pending or active work when the app
returns to the foreground. The app manifest declares the exact identifiers and
the `fetch` and `processing` background modes.

Scene reconciliation calls only `setPlaybackSuspended(_:)`: inactive and
background phases immediately remove the audible owner, while foregrounding
resumes only the still-current focus. System expiration cancels the structured
warming task. `NWPathMonitor` contributes only typed interface, constrained,
and expensive facts; Low Power Mode is sampled at execution. The engine then
enforces the stricter cellular, Low Data Mode, Low Power Mode, item, segment,
byte, concurrency, cache-validation, and elapsed-time policy.

iOS decides whether and when submitted work runs. The demo and public
documentation describe warming as opportunistic, never guaranteed.
Fixed-cardinality Codable lifecycle metrics distinguish registration,
scheduled, admitted, completed, expired, cancelled, system-denied,
policy-denied, and failed events. They compose with the warmer's cache and
origin-byte snapshot while retaining no item IDs, URLs, application metadata,
or error strings.

## Policy and capability composition

`FeedPlaybackPolicy` exposes typed presets for short-form, paged,
continuous/windowed, long-form, live, and offline-first workloads. Focused
override groups cover:

- prefetch horizon and leading-segment target;
- item, byte, memory, and disk budgets;
- global and per-origin fetch concurrency plus player-pool occupancy;
- cache expiration and eviction;
- origin network access and request/resource timeouts;
- manifest and segment retry behavior;
- looping; and
- low-power reductions to speculative work.

Existing validated network, retry, telemetry, cache, and player presets remain
the primitives underneath this policy. HLS-10 supplies stitched sources.
HLS-11 supplies a shared live-timeline model that validates feed preparation,
publishes live-edge/DVR state through Observation and bounded `AsyncStream`
snapshots, and maps high-level jump/seek controls onto the active AVPlayer
item. Both capabilities flow through HLS-16 planning and HLS-17 resource
ownership.

## Measurement contract

The engine records bounded aggregates and a lossy newest-event stream for:

| Signal | Start | End / value |
| --- | --- | --- |
| First-frame readiness | focus generation accepted | ready destination is atomically activated |
| Stall | playback was expected to advance | time control resumes or focus changes |
| Cache hit rate | cache lookup | memory, disk, miss, expired, or rejected |
| Memory / disk | residency mutation | bytes and entries after mutation |
| Cancellation | replacement plan requests stop | task finishes or misses deadline |
| Handoff | destination selected | ready lease becomes focused or fails |

Dimensions are the fixed Cartesian product of `focused`/`predicted`,
`cold`/`warm`, and `vod`/`live`/`stitched`; item IDs and URLs are never metric
keys. `HLSFeedTelemetry` owns exactly 12 path aggregates and three histograms
per path. Each histogram has at most 33 non-cumulative buckets (32 configured
bounds plus infinity). Event delivery is additionally capped at eight
subscribers with 256 newest events each. Therefore aggregate and delivery
storage has a documented constant upper bound independent of navigation or
event count.

`engine.telemetry.snapshot` is the Observation-native aggregate. The same
typed lifecycle is available through `engine.telemetry.events()`, whose
`.bufferingNewest` policy discards the oldest pending value for a slow
subscriber and increments `droppedEventCount`. Instruments signposts mark
first-frame readiness, stalls, cancellations, handoffs, and resource samples.
Every stress runner must persist or attach
`try engine.telemetry.machineReadableSummary()`; the deterministic, sorted-key
JSON snapshot includes the exact storage bound and dropped/rejected consumer
counts as well as distributions, counters, and resource high-water marks.

`HLSFeedQualificationReport` is the schema-versioned release envelope. It
combines the bounded telemetry snapshot, the stopped engine snapshot, the
validated typed policy, and fixed-cardinality outcomes for cold/no-cache,
warm-disk launch, revisit, forward/backward paging, rapid fling, direction
reversal, memory pressure, cache eviction, background/foreground, warm and
uncached offline launch, poor network, and transient failure recovery. Its
sorted-key JSON contains request and byte totals for both cache and origin,
memory/disk entries and high-water marks, eviction reasons, cancellation and
stall distributions, handoff outcomes, pool occupancy, stale focus, and leak
accounting. It deliberately contains no item IDs, URLs, request headers, or
user-derived dimensions. Missing or duplicate scenarios, failed scenarios,
budget violations, multiple audible players, stale playback, and undrained
loads all fail the report closed.

`Scripts/run-ci.sh` requires the host suite to emit
`hls-feed-qualification.json` before any simulator gate begins. The primary
vertical-feed UI qualification supplies the platform first-frame and real
paging evidence; deterministic production-backend tests supply cache, origin,
retry, offline, pressure, eviction, and cancellation evidence for the same
contract.

The first-frame timestamp is deliberately measured from accepted focus to the
engine-owned AVPlayer entering its `.playing` time-control state. A predicted
lease is not declared warm immediately after proxy readiness: the engine first
waits for AVPlayer/AVPlayerItem readiness and completes cancellable async
preroll. This moves media-pipeline loading and decode into the predictive
preparation window while keeping renderer/player startup inside the measured
handoff. A UI may layer pixel-present timing on top of the typed event stream,
but proxy readiness alone is never mislabeled as completed playback.

## Delivery graph and gates

- HLS-13: this contract, pure model, and 10,000-update planning gate.
- HLS-14: typed presets and overrides.
- HLS-15: repository-owned media, controllable local origin, and replayable
  paging/scroll traces.
- HLS-10: executable stitching contract and real routes.
- HLS-11: live edge, DVR windows, and feed-compatible controls (implemented).
- HLS-16: bounded predictive coordination and obsolete-work cancellation.
- HLS-17: pooled resources, seamless handoff, and the simple public API
  (implemented).
- HLS-18: feed-quality and resource instrumentation (implemented).
- HLS-19: SwiftUI demo proving every policy and source class (implemented).
- HLS-20: release qualification: 500 core transitions, 100 rapid UI
  navigations, p95 readiness/first-frame gates, at least 90% revisit cache hits,
  at least 99% ready handoff success, bounded resource occupancy, and sanitizer,
  release, simulator, and hosted CI evidence.
- HLS-12: retire superseded PR #4 only after every gate above is green.

## Coordinator verification

The focused coordinator suite covers a 75 ms injected-clock cancellation
acknowledgement, immediate focus reversal, stale-publication rejection,
generation-correct warm reuse, low-power caps, typed catalog failures, segment
retry, per-origin serialization, and both memory and cross-backend disk reuse.
The stress suite drives all seven standard traces (532 observations) through
the actor and asserts item, byte, and preparation-task high-water marks at every
step. The engine suite adds a deterministic 500-transition ownership run that
round-trips its machine-readable telemetry summary, generation-stale completion
rejection, failure teardown, looping/live/stitched composition, and a real
AVPlayer fixture handoff that proves the warmed player and current item are
unchanged when focus transfers. The telemetry suite drives 100,000 events
through the fixed histograms and verifies exact counters, quantiles, cache-byte
accounting, resource high-water marks, subscriber rejection, and slow-consumer
drops.

```sh
swift test --filter FeedCoordinator
swift test --filter HLSFeedEngineTests
swift test --filter HLSFeedTelemetryTests
RUN_PROXY_AV_TESTS=1 swift test --filter HLSFeedEngineAVIntegrationTests
```

The full repository, Thread Sanitizer, warning-free release, simulator, and
hosted CI gates remain mandatory before merge.
