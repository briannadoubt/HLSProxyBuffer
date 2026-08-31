# Playback analytics operations

This guide covers ingestion, retention, sampling, and dashboards for the
vendor-neutral records emitted by HLSProxyBuffer. The library does not require
an analytics SDK. Applications own the destination, credentials, consent,
retention, and deletion policy.

## Reference sinks

- `InMemoryPlaybackAnalyticsSink` retains bounded newest batches and records.
  Use it for tests and in-app previews, not durable fleet ingestion.
- `JSONLinesPlaybackAnalyticsSink` writes one canonical typed record per line
  and rotates a bounded number of local files. It never writes request headers
  or exporter credentials.
- `OSLogPlaybackAnalyticsSink` emits only aggregate record/event/summary counts
  and a signpost event. It deliberately does not log payloads, dimensions, or
  opaque identifiers.
- `HTTPSPlaybackAnalyticsSink` posts canonical batches through a caller-injected
  `URLSession`. It accepts only HTTPS endpoints, rejects insecure redirects,
  disables cookies and caching per request, bounds record/payload counts, and
  uses `deflate` only when the compressed representation is smaller.

Create a dedicated ephemeral session for HTTPS analytics. Do not share the
session, delegate, cache, cookie store, credentials, or connection policy used
for manifests and media segments:

```swift
let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.urlCache = nil
sessionConfiguration.httpCookieStorage = nil
let analyticsSession = URLSession(configuration: sessionConfiguration)

let sink = HTTPSPlaybackAnalyticsSink(
    session: analyticsSession,
    configuration: try .init(
        endpoint: URL(string: "https://analytics.example/v1/playback")!,
        authorization: .init {
            // Fetch a short-lived value for this request. Do not put it in a
            // record, disk spool, JSONL file, log, or long-lived config value.
            try await tokenProvider.authorizationHeaderValue()
        }
    )
)
```

The authorization provider runs once per request and returns the complete
`Authorization` header value. CR/LF injection and values over 8 KiB are
rejected. The value is applied after payload encoding and can never enter the
encoded batch.

## Automatic feed inspector

The `HLSProxyFeedDemo` app includes a live playback analytics inspector for
every demo mode: short form, paged, continuous/windowed, long form, live/DVR,
offline first, looping, and stitched playback. Open the floating **Inspect**
button at the lower-right of the viewport to see the bounded current-session
timeline, terminal summary, delivery
queue/backpressure health, signal counts split across AVFoundation,
proxy/origin, feed-engine, and exporter layers, plus a canonical sanitized JSON
Lines preview. Stable `analytics-*` accessibility identifiers make the same
surface available to UI qualification.

The UI test scopes its known-unique tile queries to the inspector and uses
`firstMatch` to avoid scanning the whole live timeline and export subtree.
The presentation's fixed mode is checked from a resolved accessibility
snapshot, with its identifier, label, and value attached to the test result.
This distinguishes a missing/wrong value from a remote accessibility-query
failure: a short nested predicate waiter can cancel the query before any
value is returned. Changing event counts still use asynchronous predicates;
the mode assertion and playback performance gates are not weakened.

The demo attaches exactly one sink to the engine's public typed streams. The
engine still owns every `AVPlayer`, proxy listener, cache, and buffer:

```swift
let sink = InMemoryPlaybackAnalyticsSink()
let delivery = PlaybackAnalyticsDelivery(sink: sink)

let eventTask = Task {
    for await event in engine.analytics.events {
        await delivery.record(event)
    }
}
let summaryTask = Task {
    for await summary in engine.analytics.summaries {
        await delivery.record(summary)
    }
}

// On teardown, stop the engine so its final summaries are emitted, wait for
// both stream tasks, then perform the delivery actor's bounded final flush.
await engine.stop()
await eventTask.value
await summaryTask.value
await delivery.shutdown()
```

The inspector renders only typed source/lifecycle/measurement values and the
canonical exporter codec. It never reads or displays manifest URLs, origin
addresses, request/response headers, cookies, authorization values, or player
resource objects.

## Ingestion contract

HTTPS requests use `POST`, `Content-Type: application/json`, `Accept:
application/json`, and `Cache-Control: no-store`. A `Content-Encoding: deflate`
header means the body is zlib/deflate compressed. `X-Record-Count` is an
operational size hint, not an identity.

The body is a canonical `PlaybackAnalyticsBatch`:

```json
{
  "records": [
    {"kind": "event", "event": {"recordID": "..."}},
    {"kind": "summary", "summary": {"recordID": "..."}}
  ]
}
```

The checked-in golden JSON Lines fixture is the authoritative field-order and
wire-shape example. JSON object order must not be used semantically; schema
major, kind, and typed fields are the compatibility contract.

Ingestion must deduplicate each record by `recordID` within the configured
retention window. A batch has no stable identity: retry, timeout, spool replay,
or process restart can deliver the same records in a different batch. Return
any 2xx status only after the records are durably accepted for idempotent
processing.

The HTTPS sink classifies 408, 425, 429, 5xx, invalid responses, and transport
errors as retryable. Other HTTP statuses, invalid endpoints/authorization,
insecure redirects, excess records, and oversized payloads are permanent. The
delivery actor retries unknown/retryable errors with its bounded policy and
immediately spools or drops permanent failures.

## Existing SDK adapter

An adopter bridge needs only one method. Keep vendor objects inside the sink,
map typed records without adding raw URLs or user fields, and return after the
SDK has accepted the batch:

```swift
struct ExistingSDKSink: PlaybackAnalyticsSink {
    let client: ExistingAnalyticsClient

    func send(_ batch: PlaybackAnalyticsBatch) async throws {
        try await client.ingest(batch.records.map { record in
            ExistingAnalyticsEnvelope(
                idempotencyKey: record.idempotencyID.encodedValue,
                canonicalPayload: try PlaybackAnalyticsExportCodec.encode(record)
            )
        })
    }
}
```

If the SDK exposes permanent versus retryable errors, make its error conform to
`PlaybackAnalyticsRetryClassifyingError`. Do not retry inside both the adapter
and `PlaybackAnalyticsDelivery`; choose one bounded retry owner.

## Sampling and delivery health

Routine sampling is deterministic from `RecordID`. Important events and all
terminal summaries bypass sampling. Record the configured sampling rate with
deployment metadata, not inside every event. Correct count estimates for
sampled routine events at query time; never apply that correction to important
events or summaries.

Monitor `PlaybackAnalyticsDelivery.Snapshot` separately from playback data:

- queue/spool bytes and records versus their hard limits;
- routine, important, and critical drops;
- sampled-out records;
- retries, export failures, and spool failures;
- live and maximum tasks versus `taskLimit`.

Delivery health must go to a separate operational channel to avoid recursive
analytics failures. Alert on any critical-summary drop, persistent spool
saturation, or task-limit breach.

## Retention and privacy

Choose explicit windows for raw events, terminal summaries, opaque correlation
IDs, and local spool/JSONL files. A common shape is short raw-event retention,
longer aggregated summaries, and immediate expiry of opaque IDs once joins and
deduplication are no longer needed. The application must implement consent,
regional routing, subject deletion, and backup expiry appropriate to its data.

Before export, reject any payload containing a raw media URL, host/IP address,
request/response header, authorization/cookie/token, account/email/user ID, or
an unapproved dimension. Never group by `recordID`, `sessionID`, `playbackID`,
or `itemID`.

## Dashboard-ready fields

Build fleet views from deduplicated terminal summaries and reviewed bounded
dimensions:

- first-frame p50/p95/p99 and startup-abandonment rate;
- completion rate, watch duration, stall count, and rebuffer ratio;
- cache-hit rate, origin bytes, and origin bytes avoided;
- bitrate distribution, variant switches, recovered and fatal errors;
- cancellation count and wasted bytes;
- handoff readiness/success rates;
- live-edge distance and stitched-boundary outcomes;
- peak managed memory/disk and player/proxy occupancy.

Rates are recomputed from summed sibling numerators and denominators. Latency
percentiles use raw per-session values or mergeable fixed histograms, never the
average of client percentiles. Missing optional measurements remain unknown and
must not be coerced to zero.
