# Canonical manifest reuse during native playback

Predictive preparation and `ProxyHLSPlayer` use the same internal validated
manifest loader and the same bounded segment cache. A newly created player can
therefore start from valid persisted manifests and prepared segment bytes after
an engine or app restart, without requiring a redundant manifest-origin request.

Cache keys retain the complete canonical URL, including scheme, port and query.
The transport policy is checked before cache reuse. Expired bytes require origin
validation; a successful 304 reuses the corresponding cached body, while a 304
without cached bytes fails. `no-store` removes the cached entry. Invalid new HLS
content is never written over validated content, and a failed revalidation does
not silently make expired bytes fresh.

Networking remains owned by the caller: preparation applies its existing global
and per-origin admission limits, and playback retains its configured session,
network and retry policy. No new public configuration knobs are introduced.

Finalized VOD does not start a redundant playlist-refresh loop. Live sources keep
their existing refresh path. A prepared prefix is not a fully downloaded offline
asset: playback still needs uncached segments when it reaches them, and an offline
cold-cache miss remains a failure. Preparation failures now appear in the public
engine snapshot even when no player lease could be created; they clear when the
current working set recovers.

Regression coverage includes native online playback followed by a new engine
using the same disk cache with the origin stopped, one canonical manifest request
across preparation/playback, offline cold-miss failure, expiry/304/no-store rules,
transport enforcement, canonical identity, and failure-to-recovery observation.

## Warm handoff and preparation expansion

A neighbor may already own a successfully prerolled player while its preparation
result contains fewer leading segments than the focused policy requests. Moving
focus now rebases that matching, primed lease into the accepted generation
immediately. The coordinator continues expanding the preparation target under
the same budgets, but those additional fetches do not delay the existing player.
Loading, failed, replaced-source, and retiring leases do not use this fast path.
Cancellation, focus ownership, and ordinary AVPlayer stall recovery are unchanged.

A deterministic test holds the expansion open across focus and reversal; a
native test verifies that the same buffered AVPlayer and item take focus before
expansion finishes. The 500 ms warm-start and 250 ms cancellation gates remain
unchanged. UI qualification attaches its JSON report before asserting success,
so performance failures retain machine-readable evidence as well as test logs.
