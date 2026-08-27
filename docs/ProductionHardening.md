# Production hardening

This document records the guarantees of the hardened proxy pipeline and the
boundaries operators should plan around.

## Manifest fidelity

- The parser requires `#EXTM3U`, validates explicit and implicit byte ranges,
  substitutes `EXT-X-DEFINE` variables, and rejects dangling URI-bearing tags.
- Protocol version, independent segments, playlist type, start offsets,
  discontinuity sequence, gap/discontinuity/program-date-time/date-range tags,
  unknown attributes, trailing parts, initialization maps, encryption state,
  delta skips, and rendition reports survive parse/rewrite.
- Segment, part, map, preload-hint, rendition, I-frame, image-playlist, and
  URI-backed session metadata references are rewritten to loopback. Key URIs
  are also local when `drmPolicy` is `.proxy`; `.passthrough` deliberately leaves
  key acquisition to AVFoundation. Content steering is removed after the master
  is flattened to one local variant.
- Cache and route identities include a SHA-256 fingerprint of the origin URL and
  byte range, preventing live sequence reuse from serving stale bytes.

## Concurrency and lifecycle

- Cache, catalog, fetch, refresh, and prefetch state are actor-isolated under
  Swift 6 strict concurrency.
- Prefetch work uses a bounded task group. Retries use capped exponential
  backoff, while client errors and cancellation do not retry.
- A shared single-flight table coalesces concurrent origin requests across
  prefetch and on-demand proxy paths.
- Each player load has a generation. Superseded loads, refresh callbacks, and
  rendition refreshes cannot mutate a newer session. `stopAndWait()` provides a
  deterministic teardown point.
- `ProxyHLSPlayer.stateUpdates()` and `SegmentPrefetchScheduler.states()` are
  bounded `AsyncStream` feeds; SwiftUI uses granular Observation properties.

## Cache and HTTP behavior

- Memory and disk limits are byte-based. Disk files are scoped per player,
  written atomically, read with mapped I/O when possible, and evicted by LRU.
- The listener binds explicitly to `127.0.0.1`. Routes are frozen when serving
  starts and request parsing is incremental, binary-safe, and size-limited.
- The proxy implements GET/HEAD, persistent HTTP/1.1 connections, query/path
  separation, byte ranges (`206`/`416`), correct content lengths and media MIME
  types, and no-cache playlists.
- Responses are delivered header-first and body writes are sequenced through
  Network.framework completion callbacks. A segment is still materialized as
  `Data` once so it can be validated and cached; byte budgets bound residency.

## Operational boundaries

- Origin manifests default to HTTPS. Enabling insecure manifests is an explicit
  development policy.
- FairPlay key metadata can be proxied, but license acquisition remains an app
  responsibility; key bytes are never persisted by the disk segment cache.
- This package is not an offline-download manager or a general-purpose public
  HTTP server. The local server deliberately supports the subset AVPlayer needs.
- Latency and throughput depend on origin/CDN behavior, media encoding, device
  decoding, and policy tuning. Validate target streams on real hardware.

## Release verification

Before release, run:

```sh
swift test
swift test --sanitize=thread
swift build -c release -Xswiftc -warnings-as-errors
./Scripts/run-ci.sh
```

The host suite covers parser/rewriter fidelity, byte ranges, cache eviction,
single-flight loading, scheduler concurrency, blocking reloads, Observation,
feed coordination, proxy integration, and AVPlayer integration. Simulator
availability controls the additional iOS/tvOS checks in `run-ci.sh`.
