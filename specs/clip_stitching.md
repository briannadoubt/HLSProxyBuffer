# Clip stitching contract

Status: implemented by HLS-10. This document is normative for direct stitching.

The implementation follows the March 2026 [HTTP Live Streaming 2nd Edition
draft](https://datatracker.ietf.org/doc/html/draft-pantos-hls-rfc8216bis-21),
Apple's [HLS authoring specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/),
and Apple's [HLS interstitial guidance](https://developer.apple.com/streaming/GettingStartedWithHLSInterstitials.pdf).

## Product boundary

HLSProxyBuffer will directly stitch only a nonempty ordered list of finite,
single-media VOD playlists whose callers supply the same explicit media
signature. This produces one seekable local HLS timeline without downloading,
decrypting, remuxing, or transcoding media.

Use a different mechanism outside that boundary:

| Need | Mechanism |
| --- | --- |
| App-owned sequential clips with different codecs, containers, or track layouts | Separate `AVPlayerItem` values in `AVQueuePlayer`; do not pretend they are one HLS decoding timeline |
| Client-scheduled ads or interstitial UI | [`AVPlayerInterstitialEventController`](https://developer.apple.com/documentation/avfoundation/avplayerinterstitialeventcontroller) and HLS interstitial events |
| Server-scheduled, measured, personalized, or rights-sensitive ads | An external HLS interstitial/SSAI service that owns asset lists, tracking, entitlement, and timeline semantics |
| Multivariant playlists, alternate audio/subtitles, or aligned bitrate ladders | An external packager that can stitch every rendition at identical boundaries |
| Live or LL-HLS sources | A live packager/origin; static concatenation cannot preserve reload, skip, rendition-report, and preload state |

Creating an `AVPlayerInterstitialEventController` overrides source-scheduled
interstitials, so applications must select one schedule authority. The direct
stitcher rejects `EXT-X-DATERANGE`, cue, SCTE-35, asset, and placement tags
instead of silently breaking an ad schedule.

## Public model

HLS-10 will expose these concepts (names may vary only to match project style):

```swift
struct HLSClip: Sendable, Identifiable {
    let id: String
    let playlist: MediaPlaylist
    let mediaSignature: HLSClipMediaSignature
}

struct HLSClipMediaSignature: Sendable, Equatable {
    let container: Container       // MPEG-TS or fragmented MP4
    let codecs: [String]           // normalized RFC 6381 values
    let trackLayout: [Track]       // media kind + codec + channel/layout facts
    let videoRange: String?
    let segmentsAreIndependent: Bool
}

struct ProxyPlaybackClip: Sendable, Identifiable {
    let id: String
    let playlistURL: URL
    let mediaSignature: HLSClipMediaSignature
}
```

`HLSClipStitcher` accepts parsed clips. `ProxyHLSPlayer.load(clips:)` resolves
and parses each URL using the configured origin policy, invokes the core
stitcher, installs the resulting catalog and playlist into the existing proxy,
and fails through the normal player error state. The first implementation does
not accept master playlists or infer codecs by sniffing bytes.

The signature is an assertion from a trusted packager or application. Codec
values are trimmed, lowercased, sorted, and deduplicated. Compatibility requires
exact equality of container, codec set, track layout, and video range. A
discontinuity permits timestamp and encoding-parameter changes; it is not a
license to join arbitrary decoder configurations. Inputs containing video must
assert independent segment starts.

The same typed source composes with feed preparation:

```swift
let clips = [
    ProxyPlaybackClip(
        id: "opening",
        playlistURL: openingURL,
        mediaSignature: signature
    ),
    ProxyPlaybackClip(
        id: "continuation",
        playlistURL: continuationURL,
        mediaSignature: signature
    ),
]

try await player.load(clips: clips)

let item = FeedPlaybackItem(
    id: "story",
    source: .compatibleClips(clips),
    estimatedPreparationBytes: 2_000_000
)
```

No queue, proxy URL, segment catalog, or buffer is exposed to the caller.

## Input validation and explicit failures

Validation finishes before player/catalog state changes. Errors identify the
clip index and stable reason:

- no clips, duplicate or empty clip ID, an empty playlist, a non-finite or
  nonpositive segment duration, or sequence arithmetic overflow;
- a playlist without `EXT-X-ENDLIST` or whose type is not VOD when a type is
  declared;
- LL-HLS state: parts, trailing parts, preload hints, rendition reports,
  skip state, part target, or server control;
- master/rendition topology or unsupported playlist-wide passthrough tags;
- incompatible signature or a video clip without independent segment starts;
- ambiguous program-date-time mapping (a later explicit mapping overlaps an
  earlier segment's mapped interval);
- ad/interstitial metadata that belongs to the interstitial path.

No partial output is returned. Proxy player failure leaves the previous load
superseded using the existing session-generation rules.

## Output playlist

The result is a finite VOD `MediaPlaylist` with these deterministic properties:

1. `mediaSequence` is zero and every complete segment is renumbered contiguously.
2. `EXT-X-DISCONTINUITY-SEQUENCE` is zero. Exactly one
   `EXT-X-DISCONTINUITY` precedes the first segment of each clip after the
   first. Existing internal discontinuities remain, without duplicate adjacent
   tags. The HLS discontinuity sequence number is therefore stable and
   derivable for every segment.
3. `targetDuration` covers the largest rounded segment duration. Protocol
   version is the maximum input/feature requirement (byte ranges require at
   least 4; fMP4 maps require at least 6).
4. The output declares VOD and `EXT-X-ENDLIST`. LL-HLS control, parts, hints,
   reports, and delta state are absent because such inputs are rejected.
5. `EXT-X-INDEPENDENT-SEGMENTS` is present only when every input makes that
   assertion. Session keys are de-duplicated. Playlist start offsets and
   unsupported global passthrough tags are rejected rather than applied to the
   wrong timeline.

## Segment-scoped state

- Segment URLs stay absolute origin URLs in the core model. Byte ranges remain
  explicit closed ranges, including offsets that were implicit in source text.
- Initialization maps and their byte ranges remain attached to their segments.
  HLS-10 extends `MediaInitializationMap` to capture the encryption state in
  scope when `EXT-X-MAP` was declared, because a later segment key does not
  retroactively encrypt that map. The rewriter emits the map whenever state
  changes at a join.
- Encryption state remains attached to each segment. Because an omitted AES-128
  IV derives from the original media sequence, the stitcher materializes that
  original sequence as a 128-bit hexadecimal IV before renumbering. Key changes,
  `METHOD=NONE`, and proxy key routing remain explicit. An AES-128-encrypted map
  without an explicit IV is rejected.
- Resource metadata order is the map key (when encrypted), map, segment key,
  segment metadata, `EXTINF`, byte range, and URI. This keeps independent key
  scopes valid for initialization sections and segments.
- Program date-time tags retain their source values. Forward gaps are allowed
  across a discontinuity; overlapping/backward mappings are rejected. The
  stitcher never fabricates capture times.

## Proxy routing

The existing loopback-only wildcard segment route serves stitched segments,
parts are absent, and key routes retain current DRM policy. Catalog identities
continue to include origin URL and byte-range fingerprints. Local resource
paths add a sanitized original extension (`.ts`, `.m4s`, `.mp4`, `.vtt`, and so
on), ignoring query/fragment data, with `.bin` as fallback. This preserves
AVFoundation/content-type hints without weakening identity uniqueness.

All manifest and resource URLs exposed to AVPlayer are loopback URLs. Origin
credentials stay in the configured URL sessions; raw origin URLs do not appear
in the stitched manifest. Direct stitched playback always maps key identities
onto the memory-only `/assets/keys` route, even when ordinary single-stream
playback uses passthrough DRM policy. Applications register those bytes with
`registerAuxiliaryAsset`; feed preparation never downloads or persists key
bytes in the segment cache.

## Conformance fixtures and gates

`Tests/HLSCoreTests/Fixtures/ClipStitching` is copied as a SwiftPM test resource.
`expectations.json` records signatures and expected decisions. HLS-10 provides:

- [x] parser/stitcher/rewriter golden tests for sequences, discontinuities, maps,
  keys, implicit IVs, byte ranges, program dates, and extensions;
- [x] table-driven rejection tests for codec mismatch, live/LL-HLS, ad metadata,
  invalid durations, non-independent video, and date overlap;
- [x] proxy tests that fetch every rewritten resource route and prove no origin URL
  leaks into the manifest;
- [x] an AVFoundation integration test that installs the stitched local item and
  fetches resources across the boundary, plus an incompatible-input failure
  test. The existing environment flag may skip AVFoundation execution, but the
  deterministic core and proxy conformance tests always run in CI;
- normal, Thread Sanitizer, release warnings-as-errors, and simulator CI gates
  are recorded on the HLS-10 Scope ticket and pull request for each release.
