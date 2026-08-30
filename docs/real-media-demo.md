# Real audiovisual feed demo

Normal app launches use the checked-in real media collection: 24 distinct short
excerpts and one 32-second continuous cut, in 360p and 720p H.264/AAC renditions.
The original synchronized recorded sound is retained. Open **Media credits** for
source attribution and reuse terms. The corpus is not covered by the repository's
software license; see the generated catalog and media notices.

The vertical feed, paged feed, windowed scrolling, long-form, offline-first,
looping, live/DVR and compatible stitching modes all use this collection.
Live/DVR is explicitly simulated from prerecorded footage: its six-segment
window advances over the continuous cut, declaring discontinuities at wraps.
Stitching uses the encoded tracks' measured media signatures.

Use `--synthetic-media` to explicitly select the old color-card fixtures.
`--qualification-mode` keeps the synthetic button harness; the separate
`--vertical-qualification-mode` exercises the real collection. A missing or
invalid real corpus fails visibly; it never silently substitutes synthetic video.

## Identity, caching and serving bounds

Canonical origin paths include the corpus version. Normal launch first binds
loopback port 49374 so valid persistent segment cache entries can survive launch.
If that port is occupied, the origin binds an actual ephemeral port, exposes a
cold-cache notice, and reports `cold_ephemeral_fallback`. It never fabricates a
cache hit by removing the origin port from production keys. Replacement media
must receive a new generated corpus version.

At launch the library loads metadata and validates paths/sizes/playlists, not
all media bytes. Segment resources remain file-backed. The fixture origin admits
at most four body reads, each at most 1 MiB, and queues at most 64 more. Admission
precedes the file/range read; the lease survives throttling and the transport's
send completion. Client disconnect and server shutdown cancel queued/in-flight
route work. Socket input and connection count are bounded, including pipelining.

`bodyBudget` reports conservative reserved payload bytes separately from the
engine's memory/disk caches. It is not total process RSS, decoder memory, or a
promise about kernel socket buffering. Origin response-byte counters describe
responses handed to transport, not bytes acknowledged by the remote client.
Snapshots also include corpus version and binding class without publishing URLs.

HEAD and conditional 304 requests do not materialize bodies. GET supports single
closed/open/suffix byte ranges and If-Range; If-None-Match takes precedence over
If-Modified-Since. Offline, throttling, injected failures and bounded request
accounting remain available for reproducible qualification.

## Production correctness exposed by real footage

Feed priming waits for the proxy to construct AVPlayer within the existing
five-second readiness deadline, with prompt cancellation. It does not confuse
an asynchronously published player with failed media.

Explicit VOD playlists retain their complete immutable timeline and ENDLIST,
independent of buffer readiness and playhead movement. Startup remains buffered;
uncached segments are served on demand under the existing budgets. This follows
[RFC8216's VOD mutability rules](https://www.rfc-editor.org/rfc/rfc8216.html#section-6.2.1)
and prevents AVPlayer rejecting a partially published VOD playlist.

Adaptive VOD publishes distinct, immutable rendition playlists and preserves
their segment routes. Controller decisions set AVFoundation's bitrate preference;
the native player performs the transition. Initial player construction waits for
all initial playlist metadata to be published, including on a warm cache hit.
The controller target is not a claim about which rendition was actually decoded.

Coalesced segment requests now cancel an individual waiter promptly without
cancelling other readers; the last cancelled waiter stops the origin request.
Library-owned network sessions are invalidated when their owners are released,
so successive feed engines do not accumulate idle connections. Caller-injected
sessions remain caller-owned and usable.

The synthetic qualification's 99% ready-handoff gate counts successful handoffs
that were ready against attempts that were ready. Cold attempts and failures
remain separately visible; they cannot inflate the ready-success numerator.

## Verification

Focused tests cover the full real catalog, all eight native playback modes,
versioned paths and stable/rebound origin identities, recorded-live wrap
semantics, measured stitching signatures, body-free validators, byte ranges,
body residency, client/shutdown cancellation, and ordered pipelining.

Host AVPlayer tests follow the existing opt-in convention on hosted CI
(`RUN_PROXY_AV_TESTS=1`); actual iOS playback is exercised by the real vertical
UI gate. Audiovisual decoder/frame/audio ownership and scenario qualification
are tracked separately in HLS-51. Simulator evidence does not certify physical
speaker output, lip-sync perception, or device energy consumption.
