# Adaptive Bitrate (ABR) Switching

## Overview
The proxy currently locks onto the first variant playlist (or a fixed quality) and never responds to bandwidth changes or playback failures. To behave like modern HLS clients, the player needs to monitor throughput, segment download errors, and buffer depth, then dynamically switch variants without interrupting AVPlayer.

## Requirements
- Track real-time bandwidth estimates using `HLSSegmentFetcher` metrics and maintain a smoothed bits-per-second estimate.
- Decide when to switch variants based on configurable high/low watermarks, buffer depth, and recent error signals (e.g., repeated HTTP 4xx/5xx or timeouts).
- Seamlessly transition to a new variant mid-stream by fetching its playlist, aligning media sequences, and updating the proxy playlist served to AVPlayer.
- Provide hooks for clients to pin a quality (existing `qualityPolicy.locked`) while retaining auto switching as the default.
- Emit switch events via `ProxyPlayerDiagnostics` (e.g., `onQualityChanged(profile: VariantPlaylist.Attributes)`).

## Implementation Sketch
1. **Bandwidth estimator** – Add `ThroughputEstimator` under `HLSCore/Segments` that ingests `HLSSegmentFetcher.FetchMetrics` and outputs a rolling Mbps value. Support EWMA or configurable sample windows.
2. **Variant catalog** – Extend `HLSManifest`/`VariantPlaylist` models to retain more attributes (frame rate, resolution). Keep the full variant list accessible through `ProxyHLSPlayer` even after selecting one.
3. **ABR controller** – Introduce `AdaptiveVariantController` (likely an actor) that takes the estimator, buffer state, and policy thresholds, and outputs desired `VariantPlaylist`. Policies should consider:
   - **Up-switch** when throughput exceeds next tier by buffer headroom.
   - **Down-switch** when throughput drops below current tier or consecutive segment fetches fail/time out.
4. **Playlist switch pipeline** – When the controller requests a new variant:
   - Fetch the variant playlist via `HLSManifestFetcher`.
   - Align the media sequence to maintain continuity (skip ahead until sequence >= current playhead).
   - Update `SegmentCatalog`, restart scheduler with the new playlist, and regenerate the proxy playlist.
5. **Configuration** – Extend `ProxyPlayerConfiguration` with ABR tuning knobs (min/max bitrate multipliers, hysteresis, minimum switch interval, manual override flag). Defaults should preserve existing behavior (e.g., auto mode uses thresholds, locked mode bypasses controller).
6. **Diagnostics + logging** – Log every switch with reason (throughput, failures) and expose current profile on `/debug/status`.
7. **Tests** – Add unit tests for estimator math, controller decisions with synthetic metrics, and integration tests verifying variant switches adjust the served playlist URL.

## Tasks
- [ ] Build `ThroughputEstimator` that consumes `HLSSegmentFetcher` metrics and outputs smoothed bitrate estimates.
- [ ] Expand manifest/variant models so full attribute metadata is retained and accessible for ABR selection.
- [ ] Implement `AdaptiveVariantController` with configurable policies for up/down switching driven by throughput, buffer depth, and failures.
- [ ] Create a playlist switch pipeline that fetches new variant playlists, aligns sequences, updates catalog/scheduler, and regenerates rewritten manifests.
- [ ] Add ABR-specific configuration knobs (thresholds, hysteresis, switch intervals) and ensure manual lock mode bypasses the controller.
- [ ] Emit diagnostics/log events for each switch and expose the active profile in `/debug/status`.
- [ ] Author estimator/controller unit tests plus integration tests verifying smooth variant transitions under simulated network changes.

## Acceptance Criteria
- When network throughput changes, the proxy switches to higher/lower variants without restarting playback and keeps AVPlayer fed via localhost URLs.
- Buffer depth remains stable (no complete depletion) during down-switch scenarios.
- Clients can disable ABR by setting `qualityPolicy.locked`, preserving current behavior.
- `/debug/status` and diagnostics callbacks surface the active variant name/bitrate and last switch reason.
- New automated tests validate estimator accuracy and controller decisions for at least up-switch, down-switch, and failure-triggered transitions.
