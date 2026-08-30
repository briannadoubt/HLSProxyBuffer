# Real audiovisual media for the HLS feed demo

Date: 2026-08-30

Scope: HLS-48, delivered in order through HLS-49, HLS-50, and HLS-51.

Status: Bundled-media approach approved by Bri; this written spec awaits review.

## Outcome

The primary demo shows recognizable moving footage and plays recorded dialogue,
music, or environmental sound. Real media travels through the same public feed
engine, proxy, cache, preparation, and player-handoff path as adopter content.
The demo must demonstrate audiovisual playback, not merely expose a ready state.

Keep the existing color-card and sine-tone assets as explicitly synthetic,
low-level test fixtures. Do not reopen or rewrite completed HLS-1/HLS-34 evidence.

## Chosen approach and boundaries

Bundle a compact, licensed real-media library. This makes the normal demo and
real-paging qualification reproducible, including offline and poor-network
scenarios controlled by the loopback origin. A remote-only catalog would reduce
repository size and exercise a public CDN, but its availability, response timing,
and cache policy would make those scenarios unreliable. Public-CDN qualification
can be a separate future addition; it is not required for this change.

This work does not add DRM, HDR, HEVC, 4K, user uploads, a new feed UI, or new public
engine configuration knobs. Two encoded renditions provide realistic HLS master
playlists, but their presence alone is not evidence of adaptive switching.

## Media collection and provenance — HLS-49

- Package 24 distinct short excerpts, each 8–15 seconds, plus one 32-second
  continuous excerpt for the long-form and simulated-live modes. Total packaged
  timeline duration must not exceed 240 seconds.
- Distinct means different source intervals or different source works, not new
  URLs for identical bytes. Include live-action footage, visible motion and scene
  detail, and recorded audio. Across the collection, include dialogue, music, and
  environmental/effects sound. Avoid all-black openings and deliberately silent
  excerpts.
- Use only source assets whose video and soundtrack rights permit clipping,
  transcoding, and redistribution. Prefer public-domain/CC0 or CC BY material.
  Do not assume that a site's general license covers an individual asset or its
  music. Exclude an asset if its applicable permissions cannot be verified.
- Blender's *Tears of Steel* is a candidate, not an exemption from this check.
  Its published page identifies CC BY 3.0 and a credit-scroll requirement when
  sharing the film. Resolve and preserve applicable credits before importing
  excerpts; do not assume a short footer replaces a required credit sequence.
- Store source and license URLs, author/title, copyright notices, required
  attribution, source SHA-256, excerpt time ranges, transformations, encoder
  version/settings, output SHA-256 values, and measured stream metadata in a
  checked-in provenance/catalog manifest. Third-party media keeps its own license
  and is not described as repository-owned content.
- Commit only the bounded HLS outputs and notices, not full source movies. Source
  downloads belong in a maintainer-selected cache outside tracked assets.

### Encoding and regeneration

Use SDR H.264 video with AAC-LC stereo audio at 48 kHz. Produce 640×360 and
1280×720 renditions with matching 24 fps timing and aligned, independently
decodable two-second fMP4 segments. Preserve source aspect ratio by fitting and
padding; do not stretch footage or crop away important action by default.

Both renditions retain the recorded soundtrack. Keep audio/video boundaries
aligned, retain real measured durations, and derive codec strings, bandwidth,
resolution, and track layout from encoded output rather than hand-written
assumptions. Compatible stitching clips must use matching media signatures.

The real-media bundle, including notices and manifests, has a hard 50 MiB cap;
each segment has a 1 MiB cap. Start around 1 Mbit/s video for 720p, 320 kbit/s for
360p, and 96 kbit/s audio per rendition, then enforce measured output limits.
Reject oversize output instead of silently increasing the caps or reducing clip
count. Revisit encoding settings if picture quality is inadequate.

A separate regeneration script uses pinned source checksums and recorded FFmpeg
settings. Generate into staging, validate everything, then replace only the exact
real-media output directory. Preserve `Scripts/generate-feed-fixtures.sh` and the
synthetic test corpus. CI consumes checked-in assets without downloading movies
or requiring FFmpeg regeneration. Byte-identical regeneration is required only
with the recorded encoder/toolchain version; other versions require explicit
asset review and updated provenance.

## Demo and origin integration — HLS-50

Add one typed, demo-internal media-set selection shared by the catalog, model,
and fixture origin. Normal launch and the real vertical-paging UI qualification
select the real collection. The existing button-driven qualification and fast
unit fixtures explicitly select synthetic media. No silent fallback to synthetic
content is allowed when real assets are missing or corrupt.

The media catalog owns stable IDs, accurate titles, duration, rendition paths,
preparation estimates, and attribution. Include a corpus version in canonical
paths so replacing encoded bytes cannot reuse stale persistent cache entries.
Use a stable loopback origin identity when available for cross-launch reuse.
If binding requires a different port, treat the changed canonical URL as a new
origin and report a cold-cache path. Never collapse unrelated ports or query
strings in production cache keys to manufacture a cache hit.

Serve the generated canonical playlists. Do not reuse the current synthetic
two/three-segment playlist generator for real clips. All default demo modes use
real media: feeds use short clips, looping reuses a real clip, long-form uses the
continuous cut, and live/DVR presents an explicitly labeled simulated rolling
window over prerecorded media. Stitching uses compatible real rendition
playlists and their measured signatures. Preserve the existing playback policies.

The larger corpus must not be eagerly loaded into `Data` at launch. Split small
in-memory manifest metadata from file-backed media resources. Use generated
sizes and digests for validators, resolve files only beneath the bundle root,
and read only the requested file/range. Preserve HEAD, range, conditional,
offline, throttling, fault-injection, and request-accounting behavior.

Use a typed origin serving budget: at most four concurrent materialized response
bodies, each at most 1 MiB. Admission happens before reading; cancellation releases
the slot and body. Additional work queues without materializing media. Measure
origin-owned payload residency separately from the engine's memory/disk caches;
neither counter is a claim about total process RSS or decoder memory.

Missing files, invalid metadata, or unsupported clips fail with a visible demo
error and machine-readable failure. Keep the library loader, resource serving,
and catalog mapping separate so this change does not further enlarge the model
or origin's responsibilities. Add accessible media credits without changing the
vertical-navigation interaction.

## Audiovisual qualification — HLS-51

### Encoded-asset checks

The import validator decodes both renditions of every clip and records a report
bound to their output hashes. It verifies that every referenced resource exists,
durations and variant boundaries agree, and both video and audio decode without
errors. At eight evenly spaced video sample times, at least four luma signatures
must differ. Decoded audio must contain samples, have overall RMS above −60 dBFS,
and have a peak above −40 dBFS. The collection must not be duplicated color cards
or replacement test tones. Audio/video duration mismatch must be at most 100 ms.

CI verifies the catalog, required attribution, file sizes, checksums, codec/track
metadata, and analysis-report binding. Native AVFoundation integration additionally
decodes representative packaged footage/audio so validation does not depend only
on an asserted report. Temporary decode assets may be assembled from the exact
committed fMP4 initialization and media fragments; no second source corpus is
bundled for this purpose.

### Runtime and UI checks

Use the real library with the existing engine and actual vertical swipe gestures.
Verify advancing video frames through the video output, advancing playback time,
and the presence of the expected audio track. Check focused/active/audible owner
agreement, mute state, and at most one eligible audible player during handoff,
rapid fling, reversal, backgrounding, foregrounding, and teardown.

Cover both renditions explicitly in integration tests. Exercise empty-cache
launch, warm-disk launch, revisit, offline warm reuse, offline miss, throttled
network, memory pressure, and eviction. Readiness and performance assertions must
use the real-media path; preserve the existing warm first-frame p95 ≤500 ms,
obsolete-work cancellation ≤250 ms, and configured resource limits. Record cold
first-frame and stall distributions separately rather than conflating them with
warm handoff. Do not weaken gates to hide a regression caused by realistic media.

Publish a versioned `real_audiovisual_feed` report alongside the existing reports.
It includes corpus version, scenario outcomes, decoded-frame/audio validation
counts, first-frame/handoff/stall distributions, cache/network bytes, cancellation,
cache occupancy, origin payload residency, and player/proxy bounds. Keep exported
runtime telemetry aggregate and bounded; do not include source URLs, headers,
per-request histories, or user identifiers.

Automated audio-track/sample checks and player ownership prove different things.
Neither proves that a physical speaker emitted sound or that lip sync was
perceptually correct. Inspect and listen to a simulator playback capture as a
smoke check, and document physical-device qualification separately for speakers,
audio routes, subjective sync, energy, thermals, and hardware-decoder behavior.
Do not claim device results from simulator evidence.

## Delivery and completion

1. HLS-49: reviewed media/provenance, reproducible packaging, bounded assets, and
   import/asset checks.
2. HLS-50: real media becomes the primary demo, with bounded file-backed serving,
   accurate mode mapping, and attribution.
3. HLS-51: real audiovisual integration/UI qualification, evidence export, and
   documented validation boundaries.

Keep the changes independently testable and link their branches, PRs, and evidence
in Scope. Before completion, run focused tests, the full host suite, Release
warnings-as-errors, `make ci`, and hosted sanitizer/simulator gates. HLS-48 closes
only when all three stories meet their acceptance criteria and their PRs are
merged with green CI. A spec commit alone does not complete HLS-49.

## Source references

- [Current synthetic fixture provenance](../../../Demo/HLSProxyFeedDemo/Fixtures/README.md)
- [Tears of Steel project and sharing terms](https://mango.blender.org/about/)
- [Tears of Steel credits](https://studio.blender.org/projects/tears-of-steel/pages/credits/)
- [Blender Studio asset-specific licensing guidance](https://studio.blender.org/remixing/)
- [Creative Commons attribution and adaptation guidance](https://creativecommons.org/faq/)
