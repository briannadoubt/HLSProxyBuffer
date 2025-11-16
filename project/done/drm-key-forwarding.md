# DRM / Key Metadata Forwarding

## Overview
`HLSParser` and `HLSRewriter` ignore `#EXT-X-KEY`, `#EXT-X-MAP`, and related DRM metadata, so encrypted playlists cannot traverse the proxy. This spec defines how to parse, persist, and rewrite key tags while giving applications control over how keys/CKCs are served through `/assets/keys/...` or proxied back to the original SKD URI.

## Requirements
- Parse `#EXT-X-KEY`, `#EXT-X-MAP`, and `#EXT-X-SESSION-KEY` tags into structured models, retaining attributes like METHOD, URI, IV, KEYFORMAT, and KEYFORMATVERSIONS.
- Store key metadata within `MediaPlaylist` and associate them with segments for rewriting.
- Allow `ProxyHLSPlayer.registerAuxiliaryAsset(... type: .keys)` to map identifiers to `/assets/keys/<id>` URLs and rewrite manifests accordingly.
- Support passthrough mode where key URIs remain untouched (default) plus a remap mode configurable per `ProxyPlayerConfiguration`.
- Ensure the proxy never logs or caches plaintext keys; only metadata/URIs are stored.
- Expose active key info via `/debug/status` (e.g., key method, URI hash) for observability without leaking secrets.

## Implementation Sketch
1. **Model updates** – Extend `HLSSegment` or add a `SegmentEncryption` struct referencing key attributes. Update `HLSManifest` to hold track-level default keys and `EXT-X-MAP` data.
2. **Parser work** – Enhance `HLSParser` with state machines handling key/map tags. When a key tag is seen, apply it to subsequent segments until another key overrides it. Include tests covering AES-128 and SAMPLE-AES.
3. **Rewrite logic** – Update `HLSRewriter` to emit `#EXT-X-KEY` lines before the relevant segments. Depending on configuration:
   - **Passthrough**: use original URI.
   - **Proxy**: rewrite URIs to `/assets/keys/<identifier>` or `/keys/<hash>` deriving the identifier from the auxiliary store registration.
4. **Configuration API** – Add `ProxyPlayerConfiguration.DRMPolicy` specifying passthrough vs. proxy, plus optional custom key router closure for advanced apps.
5. **Auxiliary store integration** – Allow storing CKCs or custom key payloads keyed by playlist URI hash. Provide helpers for clients to register CKCs referenced in manifests (matching docs/FairPlayStrategy.md).
6. **Security auditing** – Ensure no sensitive URIs are logged. Update loggers to redact `EXT-X-KEY` URIs when debug logging is enabled.
7. **Diagnostics & Docs** – Update `/debug/status` with sanitized fields (`active_key_method`, `key_uri_suffix`). Document usage in `docs/FairPlayStrategy.md` and add migration notes.
8. **Testing** – Add parser tests for key handling, rewriter tests verifying URIs and IVs, and end-to-end ProxyPlayerKit tests confirming AVPlayer still loads encrypted streams via local proxy.

## Tasks
- [x] Extend playlist/segment models with encryption structures capturing METHOD, URI, IV, KEYFORMAT, and MAP metadata — added `HLSKey`, `SegmentEncryption`, and `MediaInitializationMap` on `HLSManifest`/`HLSSegment`.
- [x] Update `HLSParser` to track `#EXT-X-KEY`/`#EXT-X-MAP` state and associate keys with subsequent segments plus add targeted unit tests — parser now maintains key/map state, session keys, and new XCTest coverage.
- [x] Enhance `HLSRewriter` to emit key tags before affected segments, supporting passthrough and proxy rewriting strategies — rewriter outputs session keys, map tags, and honors key resolvers.
- [x] Introduce `ProxyPlayerConfiguration.DRMPolicy` and ensure `ProxyHLSPlayer` honors passthrough vs. remapped key URIs — new config + resolver wiring in `ProxyHLSPlayer`.
- [x] Integrate auxiliary asset store helpers so registered CKCs/keys map cleanly to `/assets/keys/<id>` routes — deterministic `keyIdentifier` helper plus proxy route + tests.
- [x] Harden logging/diagnostics to redact sensitive URIs while surfacing sanitized key status via `/debug/status` — diagnostics callback and debug endpoint now emit hashed metadata only.
- [x] Document usage updates in `docs/FairPlayStrategy.md` and add parser/rewriter/proxy tests covering encrypted playlists — doc refreshed and new unit/integration coverage landed.

## Acceptance Criteria
- Encrypted HLS playlists parse successfully and retain key metadata.
- Manifests served from the local proxy include correct `#EXT-X-KEY` entries (either passthrough or rewritten) so AVPlayer continues DRM exchanges without errors.
- Auxiliary key registrations are served from `/assets/keys/...` and referenced in the rewritten playlist when configured.
- Logs and diagnostics expose only sanitized key information.
- Automated tests validate parsing and rewriting in both passthrough and proxy modes.
