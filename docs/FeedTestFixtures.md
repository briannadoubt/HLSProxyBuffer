# Deterministic feed test system

The feed test system gives coordination, cache, handoff, telemetry, UI, and
endurance work one repeatable source of truth. It never contacts the public
internet and it separates two concerns:

1. Small, playable fMP4 HLS streams exercise the real parser, proxy, cache, and
   AVFoundation path.
2. Replayable viewport traces exercise admission and cancellation decisions at
   hundreds or thousands of focus changes without making a test depend on wall
   clock timing.

## Media catalog

`Tests/ProxyPlayerKitTests/Fixtures` contains three repository-generated media
sets and one live-window playlist:

| Fixture | Shape | Intended use |
| --- | --- | --- |
| `short-a` | 3 one-second VOD fragments | Short-form and offline revisit |
| `short-b` | 3 one-second VOD fragments | Compatible stitching and handoff |
| `long-form` | 8 one-second VOD fragments | Long-form selection and seeking |
| `live` | 3-fragment rolling window, no end tag | Live edge and DVR behavior |

The short fixtures share their initialization state and encode settings, so a
stitching implementation can test a genuinely compatible pair. Provenance,
format details, and intentional regeneration instructions live beside the
assets in `Fixtures/README.md`. CI consumes committed media and does not require
FFmpeg.

## Local origin

`FeedFixtureOrigin` serves every fixture through an ephemeral localhost port.
Its immutable `Profile` can apply:

- response delay;
- a deterministic byte rate;
- attempt-scoped `503` responses;
- attempt-scoped mid-body disconnects.

The origin always supports byte ranges, strong deterministic ETags,
`If-None-Match`, `Last-Modified`, and `If-Modified-Since`. Its logical timeline
records request start, response status, each body chunk, normal completion,
client cancellation, server disconnect, attempt number, requested range, and
active request count. Logical ticks make event ordering inspectable without
asserting on unstable wall-clock timestamps.

## Navigation traces

`FeedNavigationTrace.standardCatalog` produces these framework-independent
patterns from the public feed signal contract:

- paged swipes;
- rapid focus reversals;
- continuous/windowed scrolling;
- long-form selection;
- live-window navigation;
- offline revisits;
- compatible stitched clips.

The default catalog contains 532 observations and at least 500 actual focus
changes. `FeedTraceReplayer` passes each observation through `FeedPlanner`,
tracks resident and byte high-water marks, cancellations, preparation order,
and cold/warm cache hits, and emits stable sorted JSON reports. Replaying the
same trace and cache state must produce byte-identical artifacts. A rejected
trace or plan is wrapped in `FeedTraceError`, which includes the trace name,
exact step, diagnostic, and its own stable JSON failure artifact.

These helpers live in the `ProxyPlayerKitTests` target so production binaries
carry no fixtures or fault-injection code. Later feed-coordinator, demo, and
endurance tickets should extend this shared harness instead of inventing ad-hoc
servers or public-network tests.

## Verification

Run the focused contract:

```sh
swift test --filter FeedFixtureHarnessTests
```

The repository's normal `swift test`, Thread Sanitizer, warning-free release
build, simulator CI, and hosted CI gates remain required before merge.
