# Alternate Audio & Subtitle Rendition Support

## Overview
The proxy only serves a single media playlist and ignores `#EXT-X-MEDIA` entries, preventing applications from exposing alternate audio tracks or subtitles/captions. This spec adds rendition parsing, storage, and routing so the proxy can host additional playlists or auxiliary assets and expose them to AVPlayer via the local HTTP server.

## Requirements
- Parse `#EXT-X-MEDIA` tags for AUDIO, SUBTITLES, and CLOSED-CAPTIONS types, capturing group IDs, names, language/characteristics, and associated URIs.
- Support playlists that reference alternate renditions via `#EXT-X-STREAM-INF` (AUDIO="...") and ensure rewrites keep those associations intact.
- Serve alternate playlists through the proxy, rewriting their segment URLs similarly to the main track.
- Allow applications to register out-of-band subtitle/audio assets via `AuxiliaryAssetStore` and expose them through `/assets/<type>/...` if they are not already HLS playlists.
- Expose available renditions via `ProxyHLSPlayer` API (e.g., `availableRenditions` property) and allow runtime switching.

## Implementation Sketch
1. **Modeling** – Extend `HLSManifest` to include `Rendition` structs capturing type, groupId, language, autoselect, default, characteristics, and URI. Link `VariantPlaylist` attributes to these group IDs.
2. **Parser updates** – Enhance `HLSParser` to construct rendition models when encountering `#EXT-X-MEDIA`, ensuring relative URIs resolve correctly.
3. **Rewriter changes** – When rewiring playlists, rewrite rendition URIs to proxy-hosted paths. Introduce additional `ProxyRouter` handlers for `/renditions/<group>/<name>.m3u8` or reuse playlist handler instances keyed per rendition.
4. **Player API** – Add new APIs on `ProxyHLSPlayer` (and SwiftUI wrappers) to list audio/subtitle options and switch active renditions. Switching should trigger playlist refresh or rewrites to surface the chosen rendition to AVPlayer (likely via `AVPlayerItem.selectMediaOption`).
5. **Auxiliary asset integration** – Map subtitle registrations to `#EXT-X-MEDIA` entries referencing `/assets/subtitles/...` URIs when the application provides VTT data instead of an external playlist.
6. **Diagnostics** – Include currently selected audio/subtitle group IDs in `/debug/status` and provide callbacks via `ProxyPlayerDiagnostics` when selection changes.
7. **Testing** – Add parser tests covering multiple rendition tags, rewriter tests confirming URIs and associations, plus ProxyPlayerKit tests showing that available renditions are surfaced and selection triggers the correct rewrites.

## Tasks
- [x] Extend manifest models with `Rendition` structs tied to `VariantPlaylist` group IDs.
- [x] Update `HLSParser` to capture `#EXT-X-MEDIA` metadata (audio, subtitles, captions) and resolve their URIs.
- [x] Add proxy playlist/segment handlers for rendition playlists, rewriting their segment URLs for localhost delivery.
- [x] Expose rendition listings and selection APIs on `ProxyHLSPlayer`, wiring choices through SwiftUI/UIKit surfaces.
- [x] Integrate auxiliary asset registrations so custom VTT/audio blobs map to `/assets/<type>/...` URIs and corresponding `#EXT-X-MEDIA` entries.
- [x] Surface active rendition info via diagnostics and `/debug/status`, including callbacks when selections change.
- [x] Create parser/rewriter tests plus ProxyPlayerKit tests verifying that renditions appear and switching updates playback.

## Acceptance Criteria
- Manifest parsing preserves alternate audio/subtitle metadata and exposes it through public APIs.
- Local proxy serves rewritten rendition playlists/segments so AVPlayer can load non-default tracks via localhost URLs.
- Applications can list and switch renditions at runtime with immediate effect on playback.
- Diagnostics/metrics include the active rendition names.
- Automated tests cover parsing, rewriting, and API exposure for at least one audio and one subtitle rendition scenario.
