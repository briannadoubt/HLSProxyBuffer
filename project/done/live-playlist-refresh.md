# Live Playlist Refresh & Resync

## Overview
AVPlayer only receives the proxy’s initial playlist snapshot. Without periodic refreshes the proxy never sees newly published media sequences, so live and long-form VOD streams stall once the initially fetched segments finish. This spec introduces a refresh engine that repeatedly fetches media playlists, reconciles media sequence numbers, and heals diverged state between the remote manifest, cache, scheduler, and rewritten playlist served to AVPlayer.

## Requirements
- Poll the active media playlist on a configurable cadence (default 2 seconds or target duration/2) while playback is active.
- Detect updated `#EXT-X-MEDIA-SEQUENCE`, added segments, and end-of-list markers; update `SegmentCatalog`, `SegmentPrefetchScheduler`, and buffered playlist state accordingly.
- Handle HTTP/network failures with exponential backoff while keeping the proxy playlist consistent.
- Surface refresh metrics (last refresh date, failure count) through `/debug/status` and `ProxyPlayerDiagnostics`.
- Stop refreshing when playback stops, the playlist reaches `#EXT-X-ENDLIST`, or when the player tears down.

## Implementation Sketch
1. **New refresher actor** – Add `PlaylistRefreshController` under `Sources/HLSCore` that accepts a remote URL, fetch policy, and callback for delivering new `MediaPlaylist` objects. The controller should reuse `HLSManifestFetcher` for network IO and expose `start()`, `stop()`, and `updateConfiguration()` APIs.
2. **Integrate with ProxyHLSPlayer** – Instantiate the controller inside `ProxyHLSPlayer`, wiring callbacks to:
   - Parse the refreshed text via `HLSParser`.
   - Update `SegmentCatalog` and `scheduler.enqueueUpcomingPlaylists` / `scheduler.start` with delta segments.
   - Re-run `rewriter.rewrite` whenever `BufferState` or manifest changes.
3. **State reconciliation** – When a new playlist arrives, ensure sequences less than the playhead remain available for a small history window, and remove stale cached entries beyond `EXT-X-ENDLIST`.
4. **Diagnostics** – Extend `ProxyPlayerDiagnostics` plus `/debug/status` JSON with fields like `"last_playlist_refresh"`, `"refresh_failures"`, and `"remote_media_sequence"`.
5. **Configuration** – Extend `ProxyPlayerConfiguration.BufferPolicy` with `refreshInterval` and `maxRefreshBackoff`. Persist defaults and plumb them through `ProxyHLSPlayer` -> refresher.
6. **Tests** – Add `PlaylistRefreshControllerTests` verifying polling cadence, retry behavior, and delta delivery using stubbed URLProtocol data. Update `ProxyPlayerKitTests` to assert playlists advance when new segments appear.

## Tasks
- [x] Implement `PlaylistRefreshController` actor under `HLSCore` with configurable intervals/backoff and callbacks.
- [x] Wire the refresher into `ProxyHLSPlayer`, updating parsing, catalog, scheduler enqueue/start, and rewrite triggers on every refresh.
- [x] Add reconciliation logic so cached segments and scheduler state drop stale items and retain recent history windows after refreshes.
- [x] Extend diagnostics (`ProxyPlayerDiagnostics`, `/debug/status`) with refresh timestamps, media sequence, and failure counters.
- [x] Add buffer policy configuration knobs for refresh cadence/backoff and ensure they plumb through configuration updates.
- [x] Write unit/integration tests covering refresh cadence, retry/backoff, and playlist advancement plus update docs describing tuning guidance.

## Acceptance Criteria
- Proxy serves newly appended segments for rolling live playlists without reloading the entire player.
- Scheduler metrics show continuous ready segments for streams longer than the initial playlist duration.
- `/debug/status` exposes the latest remote media sequence and refresh timestamps, updated at least once per interval.
- Automated tests cover success, HTTP error retry, and playlist end detection.
- Documentation in `docs/` or `specs/` briefly notes how to tune refresh behavior.
