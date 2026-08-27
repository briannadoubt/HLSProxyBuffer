# Playback analytics contract

`PlaybackAnalytics` is the public, vendor-neutral schema used by the feed
engine, proxy, cache, origin transport, AVFoundation collector, and exporters.
It is intentionally smaller than the diagnostics available inside each layer:
only fields that can be bounded and sanitized cross the analytics boundary.

## Correlation and time

Create one `SessionID` for an analytics collection session, one `PlaybackID`
for every playback attempt, and one `ItemID` for the media identity within that
session. These are library-generated UUIDs. They are not application account,
feed, catalog, or URL identifiers. `RecordID` supplies an idempotency key for
delivery and retry.

`TimelineClock` captures a Unix-millisecond wall-clock anchor and a monotonic
origin once. Every event then carries only elapsed nanoseconds from that
anchor. Duration and ordering calculations use `elapsedNanoseconds`; wall time
is reconstructed only for fleet time windows. This prevents clock corrections
from creating negative startup, stall, or watch durations.

```swift
let clock = PlaybackAnalytics.TimelineClock()
let correlation = PlaybackAnalytics.Correlation(
    sessionID: .init(),
    playbackID: .init(),
    itemID: .init()
)

let event = try PlaybackAnalytics.Event(
    correlation: correlation,
    timestamp: clock.timestamp(),
    source: .feedEngine,
    lifecycle: .focusRequested
)
let deterministicJSON = try PlaybackAnalytics.Codec.encode(event)
```

## Bounded dimensions

Callers declare at most eight dimension keys and at most 32 approved values per
key. Keys and values are lowercase ASCII tokens containing only letters,
digits, and underscores. Sensitive key components such as `url`, `ip`,
`header`, `authorization`, `token`, `cookie`, `user`, and `email` are rejected.
An event rejects keys absent from its catalog. A candidate value absent from
the approved set—including a URL, IP address, email address, UUID, or other
high-cardinality value—is immediately replaced with `other`; the original is
not retained.

```swift
let dimensions = try PlaybackAnalytics.DimensionCatalog(allowedValues: [
    "feed_mode": ["short_form", "paged", "continuous", "long_form"],
    "media_kind": ["vod", "live", "stitched"],
    "cache_reuse": ["cold", "warm"],
])

let safe = try dimensions.dimensions(from: [
    "feed_mode": "short_form",
    "cache_reuse": "warm",
])
```

Measurements are finite numbers with bounded names and typed units. Textual
errors, URLs, rendition URIs, server addresses, headers, and credentials are
not measurement values. Collectors convert those details to approved
categories and numeric facts before constructing an event.

## AVFoundation collection

`AVPlaybackMetricCollector` follows an `AVPlayer` across `currentItem`
replacement and publishes sanitized `.avFoundation` events through a bounded
`AsyncStream`. On iOS 18, tvOS 18, macOS 15, Mac Catalyst 18, and visionOS 2 or
newer, it consumes the player's native `AVPlayerItem.allMetrics()` sequence.
That path captures startup and likely-to-keep-up timing, stalls, rate and seek
changes, variant switches, recoverable and fatal errors, HLS playlist/segment/
content-key resource counts, and the terminal playback summary described in
[Explore media performance metrics in AVFoundation](https://developer.apple.com/videos/play/wwdc2024/10113/).

Earlier deployments use an explicitly identified `legacyFallback` path built
from player/item observable state, access and error logs, and playback
notifications. The fallback deliberately reports less detail rather than
inventing native metrics. Both paths map into the same versioned contract.

```swift
let correlation = PlaybackAnalytics.Correlation(
    sessionID: .init(),
    playbackID: .init(),
    itemID: .init()
)
let collector = AVPlaybackMetricCollector(correlation: correlation)
collector.attach(to: player)

for await event in collector.events {
    // Send the typed event to the bounded delivery pipeline.
}

collector.stop()
```

Collection is item-generation scoped: replacement stops the previous source,
and late events from that source are rejected. `stop()` invalidates the player
observation, cancels the native metrics task or every fallback observer, and
finishes the stream. The public `Snapshot` exposes the selected path, bounded
stream drops, and live task/observer counts so teardown is directly testable.

The native adapter reads resource objects only long enough to derive numeric
duration, byte, cache, success, and typed request-count measurements. URLs,
server addresses, request/response headers, native session identifiers, error
objects, and error text never cross the adapter boundary. The legacy adapter
applies the same rule to access/error logs.

## Automatic cross-layer timeline

`HLSFeedEngine.analytics` is the default integration point for feed products.
The engine creates an opaque attempt when a prepared item enters its player
pool and preserves that correlation while prediction becomes focus, a warm
player is handed off, the proxy is reused, or the feed generation advances.
Applications consume one bounded sequence and do not join player, proxy,
origin, cache, or scheduler streams themselves:

```swift
for await event in engine.analytics.events {
    await exporter.accept(event)
}
```

The engine merges `HLSFeedTelemetry`, `HLSStreamingTelemetry`, player state,
and `AVPlaybackMetricCollector` events onto one monotonic clock. Every event
contains a `timeline_sequence` measurement for deterministic ordering and the
same three opaque correlation identifiers for the lifetime of the attempt.
Late callbacks carry an unforgeable attempt token and are rejected after pool
reuse or teardown.

Attribution is fixed-cardinality. `cache_reuse` distinguishes cold and warm
preparation; `feed_intent` distinguishes focused and predicted work;
`media_kind` distinguishes VOD, live, and stitched playback; `network_leg`
distinguishes AVPlayer-to-local-proxy from local-proxy-to-origin work; and
`cache_tier` distinguishes memory, disk, origin, or not-applicable work. Raw
URLs, item identifiers, rendition names, error messages, and cancellation
reasons are never dimensions.

`PlaybackAnalyticsTimeline.Configuration` bounds its newest-event buffer,
terminal-summary buffer, and active attempt table. The snapshot exposes event
and summary emissions/drops plus stale and evicted counts. Engine shutdown
cancels streaming and native AV metrics tasks, retires every attempt, and
finishes both analytics streams. Standalone users may
also feed sanitized adapters to `PlaybackAnalyticsTimeline`, but normal feed
adopters only need the engine-owned stream.

## Terminal session summaries

`PlaybackAnalyticsTimeline.summaries` publishes exactly one bounded
`PlaybackAnalytics.Summary` for every attempt. Normal terminal calls, attempt
table eviction, and timeline shutdown all finalize through the same
`PlaybackSessionSummarizer`; a finalized accumulator rejects a second summary.
The summary stream has its own configurable newest-value buffer, and
`Snapshot.emittedSummaryCount` / `droppedSummaryCount` make downstream
backpressure visible.

```swift
for await summary in engine.analytics.summaries {
    await delivery.record(summary)
}
```

Standalone collectors can construct `PlaybackSessionSummarizer` with one
correlation and monotonic start timestamp, call `record(_:)` with sanitized
events, then call `finish(reason:endedAt:dimensions:)` once. The accumulator
retains scalar totals, peaks, and gauges only—never event history. Incremental
events add counters. A native `.summaryEmitted` event merges counters by
maximum, so AVFoundation's terminal snapshot does not count its earlier delta
events twice. An observed `.completed` lifecycle wins over a later routine
slot-release cancellation or incomplete shutdown, keeping the terminal reason
and `completion_count` reconciled with the source timeline.

Terminal meanings are intentionally distinct:

- `completed`: the media reached its product-defined successful end.
- `abandonedBeforeStart`: the attempt ended before first frame because focus
  moved or the user left, rather than a transport failure.
- `cancelled`: the owning task or explicit product action cancelled playback.
- `backgrounded`: the app intentionally finalized because its lifecycle moved
  playback to the background.
- `crashed`: a caller's next-launch recovery classified a previously durable
  in-flight marker as a process crash. Crash handlers must not perform export.
- `failed`: playback ended because of a fatal player, proxy, or origin failure.
- `incomplete`: bounded eviction or orderly analytics shutdown found an attempt
  without another terminal outcome.
- `interrupted`: an external interruption ended an otherwise valid attempt.

No-first-frame attempts report `startup_abandonment_count = 1`; their
`first_frame_latency` is absent rather than zero. The terminal reason explains
why the abandonment happened.

### Metric definitions

Every rate carries its numerator and denominator as sibling measurements.
Counts and bytes are known zeros when no matching event was observed. Optional
latencies, gauges, and rates are omitted when their source or denominator was
not observed; omission means unknown, never zero.

| Summary measurement | Unit | Per-attempt definition / denominator | Nil rule |
| --- | --- | --- | --- |
| `startup_duration` | seconds | Maximum native initial-startup duration; gauge, no denominator | Omit without a native startup sample |
| `first_frame_latency` | seconds | First engine first-frame latency from attempt start; gauge | Omit before first frame |
| `startup_abandonment_count` | count | `1` when first-frame numerator is absent, otherwise `0`; denominator is one summary | Never nil |
| `watch_duration` | seconds | Maximum of native watch duration and monotonic time from first frame to terminal | Never nil; zero means no watched time |
| `completion_count` | count | `1` only for `completed`; denominator is one summary | Never nil |
| `stall_count` | count | Sum of stall deltas, reconciled by maximum with native terminal count | Never nil |
| `stall_duration` | seconds | Maximum of summed timed stalls and native stall-recovery duration | Never nil |
| `rebuffer_ratio` | ratio | `stall_duration / (watch_duration + stall_duration)` | Omit when denominator is zero |
| `average_bitrate` | bits/second | Arithmetic mean of bounded observed average-bitrate gauges | Omit without a bitrate sample |
| `peak_bitrate` | bits/second | Maximum observed peak-bitrate gauge | Omit without a bitrate sample |
| `variant_switch_count` | count | Sum of switch outcomes, reconciled with native terminal count | Never nil |
| `recoverable_error_count` | count | Sum of sanitized recovered-error signals, reconciled with native terminal count | Never nil |
| `fatal_error_count` | count | Fatal signals; at least `1` for `failed` or `crashed` | Never nil |
| `cache_hit_count` | count | Sum of bounded cache-hit deltas | Never nil |
| `cache_miss_count` | count | Sum of bounded cache-miss deltas | Never nil |
| `cache_hit_rate` | ratio | `cache_hit_count / (cache_hit_count + cache_miss_count)` | Omit when request denominator is zero |
| `origin_bytes` | bytes | Sum of proxy-to-origin response bytes | Never nil |
| `origin_bytes_avoided` | bytes | Sum of bytes served without origin transfer | Never nil |
| `cancellation_count` | count | Maximum of explicit count and acknowledged + late + failed cancellations; at least `1` for a cancelled terminal | Never nil |
| `wasted_bytes` | bytes | Bytes completed after work became obsolete | Never nil |
| `handoff_attempt_count` | count | Sum of player handoff attempts; denominator for both handoff rates | Never nil |
| `handoff_ready_count` | count | Attempts whose destination was ready at handoff | Never nil |
| `handoff_success_count` | count | Attempts that completed seamless handoff | Never nil |
| `handoff_readiness_rate` | ratio | `handoff_ready_count / handoff_attempt_count` | Omit when attempt denominator is zero |
| `handoff_success_rate` | ratio | `handoff_success_count / handoff_attempt_count` | Omit when attempt denominator is zero |
| `live_edge_distance` | seconds | Last monotonic live-edge distance gauge before terminal | Omit for non-live or unobserved live playback |
| `stitched_boundary_success_count` | count | Sum of successful stitched transitions | Never nil |
| `stitched_boundary_failure_count` | count | Sum of failed stitched transitions | Never nil |
| `peak_memory_resident_bytes` | bytes | Maximum observed managed memory occupancy | Omit without a resource sample |
| `peak_disk_resident_bytes` | bytes | Maximum observed managed disk occupancy | Omit without a resource sample |
| `peak_player_pool_occupancy` | count | Maximum observed allocated-player count | Omit without a resource sample |
| `peak_proxy_pool_occupancy` | count | Maximum observed proxy count | Omit without a resource sample |

Summary dimensions stay fixed-cardinality: `cache_reuse` (`cold`/`warm`),
`feed_intent` (`focused`/`predicted`), `media_kind`
(`vod`/`live`/`stitched`), `network_leg`, and `cache_tier`. `Summary.source`
identifies the engine; event source is never copied into a high-cardinality
dimension. The final attribution is used after a predicted attempt becomes a
focused warm handoff.

### Fleet calculations

Deduplicate summaries by `RecordID`, filter on a compatible schema major, then
group only by reviewed bounded dimensions and terminal reason. For a group of
session first-frame values `[80, 100, 120, 200, 400]` ms, sort the raw session
values and use the ingestion system's documented nearest-rank or interpolated
quantile consistently: nearest-rank produces p50 = 120 ms, p95 = 400 ms, and
p99 = 400 ms. Do not average client percentiles.

Fleet completion rate is `sum(completion_count) / deduplicated_summary_count`.
Startup-abandonment rate uses the same denominator. Cache-hit and handoff rates
must be recomputed from summed sibling numerators and denominators; never
average per-session ratios. Omit groups whose summed denominator is zero.
Opaque session, playback, item, and record identifiers are correlation and
deduplication keys only, never grouping dimensions.

## Bounded delivery

`PlaybackAnalyticsDelivery` is an actor-backed boundary between playback and an
application-owned destination. Its two `record` overloads only perform bounded
memory admission on the actor. They never call a sink and never perform disk or
network I/O. One worker owns batching, retries, and export; optional spool I/O
runs off the actor so a slow filesystem cannot hold up new playback records.

```swift
struct FleetSink: PlaybackAnalyticsSink {
    func send(_ batch: PlaybackAnalyticsBatch) async throws {
        // Map the typed records into the application's analytics SDK.
        // Honor cancellation and return only when this batch is accepted.
    }
}

let delivery = PlaybackAnalyticsDelivery(
    sink: FleetSink(),
    configuration: .init(
        routineSamplingRate: 0.25,
        memoryBudgetBytes: 512 * 1_024,
        maximumBatchRecordCount: 64,
        flushInterval: .seconds(5),
        retryPolicy: .init(maximumAttempts: 3)
    )
)

for await event in engine.analytics.events {
    await delivery.record(event) // no sink, disk, or network await
}
```

Every `PlaybackAnalyticsRecord` exposes its existing `RecordID` as
`idempotencyID`, and every batch exposes those IDs in order. Delivery is
at-least-once: a sink can accept a request whose response is then lost, or a
spool-file delete can fail after acceptance, so a conforming destination must
deduplicate by record ID. Batch boundaries are not identities and may change
across retries or process launches.

Routine sampling is deterministic from `RecordID`; important events and all
summaries bypass sampling. When the memory queue is full, a higher-priority
record evicts the oldest record at the lowest lower priority. A routine record
never displaces another record, and a critical summary is dropped only when no
lower-priority record can make room. The disk spool applies the same rule,
stores only typed records, uses one file per idempotency key, and is bounded by
both bytes and record count. Its directory is application configuration and is
never included in analytics data.

`snapshot` and the newest-only `snapshots` stream expose queue/spool occupancy,
sampling and priority drops, retries, export/spool failures, deliveries, and
live/maximum task counts. Delivery health is local state; it is deliberately
not emitted into the analytics pipeline, avoiding recursive failure reports.
`flush()` performs one immediate best-effort pass. `shutdown(flushTimeout:)`
stops admission, cancels the scheduled worker, attempts a deadline-bounded
flush, spools or drops anything left, and finishes the health stream. Sink
implementations must honor Swift task cancellation so that deadline and task
bounds remain enforceable.

## Reference exporters

`PlaybackAnalyticsExportCodec` supplies deterministic batch and JSON Lines
encodings. The package includes bounded in-memory and rotating JSONL sinks, an
OSLog/signpost sink that logs aggregate counts only, and an HTTPS sink with an
injected dedicated session, per-request ephemeral authorization, bounded
deflate compression, HTTPS redirect enforcement, and typed retry disposition.
No third-party analytics dependency is required.

See [Playback analytics operations](PlaybackAnalyticsOperations.md) for the
ingestion/idempotency contract, a small existing-SDK adapter, session isolation,
sampling, privacy/retention, alerting, and dashboard-ready fields.

## Schema compatibility

The schema uses `{major, minor}` versions.

- Major `1` is supported. A different major is rejected before decoding the
  rest of a record.
- A higher minor is accepted. Unknown JSON fields are ignored and bounded
  unknown source, lifecycle, terminal-reason, and unit tokens round-trip.
- Fields added in a minor version must be optional or have a decoder default.
  `priority`, `dimensions`, and `measurements` currently default to `routine`,
  empty, and empty for the checked-in minimal v1 fixture.
- Removing or changing the meaning, type, or unit of a field requires a new
  major version. Adding an enum case or optional field is a minor change.

`PlaybackAnalytics.Codec` is the canonical encoder. It sorts object keys,
preserves slash characters, sorts measurements by name, rejects duplicate
measurements, and has byte-for-byte golden event and summary fixtures under
`Tests/ProxyPlayerKitTests/Fixtures/Analytics`.

## Fleet aggregation and privacy

| Field | Classification | Fleet use |
| --- | --- | --- |
| Schema version, source, lifecycle, terminal reason, priority | Fleet safe | Grouping and compatibility filters |
| Approved dimensions | Fleet safe | Grouping only after the application-owned finite catalog is reviewed |
| Numeric measurements and monotonic elapsed time | Fleet safe | Sums, rates, and latency distributions; never use an opaque ID as a dimension |
| Wall-clock anchor | Fleet safe | Coarse ingestion/time-window alignment, not user behavior identity |
| Record, session, playback, and item IDs | Opaque correlation | Join and idempotency within retention; never fleet grouping or user identity |
| Raw media URLs, IP/server addresses, request/response headers | Forbidden | Never construct, encode, spool, log, or export |
| Authorization, cookies, credentials, tokens, user/account/email IDs | Forbidden | Never construct, encode, spool, log, or export |

`PlaybackAnalytics.privacyManifest` exposes the same classification in code.
Exporters must use the typed `Event` and `Summary` values rather than accepting
arbitrary dictionaries. Authentication belongs to an ephemeral sink request
configuration and never to an event, summary, or disk spool.

## Runtime opt-out and release qualification

Analytics is enabled by default. Set
`PlaybackAnalyticsTimeline.Configuration(isEnabled: false)` through
`HLSFeedEngine`'s `analyticsConfiguration` when a product must disable the
ordered analytics timeline entirely. The engine then skips analytics attempt
storage, event and summary emission, streaming-telemetry subscriptions, and
AVFoundation metric observers. Fixed-cardinality `HLSFeedTelemetry` remains
available for local playback health. This explicit switch is also the baseline
for the release overhead gate; it is not a sampling shortcut.

The release qualification alternates enabled and disabled runs of the same
local-fixture rapid-navigation workload after warmup. The median enabled-minus-
disabled first-frame p95 must be at most 5 ms, and the positive process CPU-
utilization delta must be at most two percentage points. A separate integrated
100,000-event run proves timeline, summary, queue, memory, task, subscriber,
and drop bounds; slow and offline sinks prove shedding, bounded disk spooling,
critical-summary survival, and recovery. Canonical batch, JSON Lines, and spool
payloads are scanned for URLs, addresses, headers, credentials, user data, and
unapproved application identifiers.

Address Sanitizer runs the correctness, privacy, recovery, and lifetime suite;
explicit weak-lifetime assertions fail on retained timelines or delivery actors,
and Thread Sanitizer runs every non-performance test. Release JSON reports,
sanitizer logs, and the Release-mode iOS simulator result bundle are uploaded
together by hosted CI. See [Automatic feed release qualification](FeedQualification.md)
for artifact names and reproduction commands.

## Aggregation rules

Fleet systems aggregate numeric measurements by schema major, source,
lifecycle or terminal reason, and reviewed dimensions. Rates must publish both
the numerator and denominator. Percentiles are calculated from numeric values
or fixed histograms, never by averaging client percentiles. Missing
measurements mean unknown/not observed, not zero. Event and summary counts are
deduplicated by `RecordID`; opaque correlation IDs must expire with the
configured analytics retention window.
