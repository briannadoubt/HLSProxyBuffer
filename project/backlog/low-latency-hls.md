# Low-Latency HLS (LL-HLS) Support

## Overview
The current low-latency options only toggle server-control flags and prefetch hints; they do not parse or emit `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT`, or blocking reload semantics required for LL-HLS. This spec adds true LL-HLS support so the proxy can ingest partial segments, rewrite them with localhost URLs, and keep AVPlayer fed with sub-second latency.

## Requirements
- Parse LL-HLS specific tags: `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT`, `#EXT-X-RENDITION-REPORT`, `#EXT-X-SKIP`, and blocking reload attributes.
- Extend segment models to represent partial segments (duration, byte-range, URI) and map them to scheduler/cache identities.
- Prefetch scheduler must understand part-level buffering, scheduling micro-chunks before full segments complete.
- Rewriter emits part tags targeting proxy URLs, including optional GAP/INDEPENDENT attributes, and handles `#EXT-X-PRELOAD-HINT` rewrites.
- Support blocking playlist reload by letting the refresher (see live-refresh spec) honor `CAN-BLOCK-RELOAD` and `PART-HOLD-BACK` values.
- Provide configuration to enable LL-HLS, including part buffer depth targets and fallback logic when the stream downgrades to traditional segments.

## Implementation Sketch
1. **Model extensions** – Introduce `HLSPartialSegment` and augment `MediaPlaylist` with arrays of parts tied to their parent `HLSSegment`. Keep track of hints and rendition reports for rewrites.
2. **Parser updates** – Teach `HLSParser` to construct partial segments, parse blocking reload attributes, and record skip boundaries. Ensure compatibility with playlists that mix parts and full segments.
3. **Segment identity & cache** – Update `SegmentIdentity` to generate stable keys for parts (e.g., `part-{sequence}-{partIndex}`). Modify `HLSSegmentCache` and `SegmentHandler` to store/serve part data separately while still exposing aggregate metrics.
4. **Scheduler** – Expand `SegmentPrefetchScheduler` to compute buffer depth using parts, fetch partial segments via `HLSSegmentFetcher`, and surface telemetry about part readiness. Provide hooks to drop old parts once fully consumed.
5. **Rewriter** – Use new models to render `#EXT-X-PART` tags referencing `segmentURL` variants plus per-part suffix/prefix. Include `#EXT-X-PRELOAD-HINT` rewrites for upcoming parts and integrate delta update tags.
6. **Playlist refresh + blocking reload** – When LL-HLS is enabled, the refresher should optionally perform blocking reload requests (long polling) and obey hold-back/prefetch counts from configuration.
7. **Diagnostics** – Extend `/debug/status` to report part readiness counts, hold-back seconds, and whether blocking reload is engaged.
8. **Testing** – Add fixtures for LL-HLS playlists to parser/rewriter tests. Update scheduler tests for part scheduling. Consider integration test ensuring AVPlayer consumes part playlists.

## Tasks
- [ ] Define `HLSPartialSegment`/hint/rendition-report models and attach them to `MediaPlaylist` + `HLSSegment`.
- [ ] Upgrade `HLSParser` to recognize LL-HLS tags (`PART`, `PRELOAD-HINT`, `RENDITION-REPORT`, `SKIP`, blocking reload attrs) with fixtures validating mixed playlists.
- [ ] Enhance `SegmentIdentity`, `HLSSegmentCache`, and `SegmentHandler` to store/fetch individual parts with stable identifiers.
- [ ] Extend `SegmentPrefetchScheduler` to plan/fetch parts, maintain part-level buffer depth, and drop consumed parts.
- [ ] Update `HLSRewriter` to emit part tags, preload hints, and skip metadata pointing to proxy URLs.
- [ ] Teach the playlist refresher to support blocking reload requests and respect hold-back/prefetch settings when LL-HLS is enabled.
- [ ] Add diagnostics fields for part readiness/hold-back along with logging to confirm LL-HLS mode status.
- [ ] Implement parser/rewriter/scheduler tests plus integration coverage ensuring AVPlayer consumes LL-HLS playlists via the proxy.

## Acceptance Criteria
- Proxy can ingest an LL-HLS stream containing partial segments and continue serving them locally with latency comparable to the origin.
- Rewritten playlists include correct `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT`, and server-control tags pointing to localhost URLs.
- Scheduler telemetry reflects part-level buffering and avoids stalling even when only parts are available.
- Blocking reload and delta updates function according to configuration without starving AVPlayer.
- Tests cover parsing, rewriting, and scheduling of part metadata with both LL-HLS enabled/disabled pathways.
