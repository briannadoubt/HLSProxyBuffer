# Low-Latency HLS

The proxy can now ingest and serve Low-Latency HLS (LL-HLS) playlists end to
end. Partial segments (`#EXT-X-PART`), preload hints, rendition reports, and
blocking reload semantics are preserved throughout the stack so AVPlayer can
stay within a sub-second latency window while still using the local proxy.

## Enabling LL-HLS

`ProxyPlayerConfiguration` exposes two knobs:

1. `lowLatencyPolicy` – enables the runtime behavior (part prefetch counts,
   blocking playlist reloads, refresher timeouts).
2. `lowLatencyOptions` – forwarded into `HLSRewriteConfiguration` to emit
   server-control flags, delta-update hints, and prefetch metadata.

```swift
var config = ProxyPlayerConfiguration()
config.lowLatencyPolicy = .init(
    isEnabled: true,
    targetPartBufferCount: 3,
    enableBlockingReloads: true,
    blockingRequestTimeout: 5
)
config.lowLatencyOptions = .init(
    canSkipUntil: 6,
    partHoldBack: 0.6,
    allowBlockingReload: true,
    prefetchHintCount: 2,
    enableDeltaUpdates: true
)
```

When `lowLatencyPolicy.isEnabled` is true the proxy:

- Prefetches partial segments independently of full segments, maintaining the
  configured part buffer depth.
- Rewrites `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT`, and `#EXT-X-RENDITION-REPORT`
  tags to localhost URLs so AVPlayer always stays on the proxy path.
- Issues blocking playlist reload requests (`?_HLS_msn=…&_HLS_part=…`) when the
  upstream manifest advertises `CAN-BLOCK-RELOAD=YES`, and falls back to
  `PART-HOLD-BACK` driven refresh cadence otherwise.
- Surfaces part readiness/hold-back telemetry via `/debug/status` and
  `/metrics`.

If the stream downgrades to legacy HLS (no LL tags) the proxy gracefully
continues using full segments. Disabling `lowLatencyPolicy` restores the legacy
behavior even when `lowLatencyOptions` is still populated.

## Diagnostics

The `/debug/status` payload now includes:

- `ready_part_sequences` – per-sequence part counts.
- `part_prefetch_depth_seconds` – aggregate duration of prefetched parts.
- `part_hold_back_seconds` – most recent `PART-HOLD-BACK` from the manifest.
- `blocking_reload_active` – whether long-poll playlist reloads are engaged.

Prometheus metrics expose `hlsproxy_buffer_ready_parts` and
`hlsproxy_part_buffer_depth_seconds` for alerting.

Use these values to tune `targetPartBufferCount`, hold-back settings, and
blocking request timeouts for each deployment.
