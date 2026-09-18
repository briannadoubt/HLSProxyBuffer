# Forward buffer correctness across policy changes and rewind

A visibility policy change calls `updateConfiguration`, which re-enqueues the
upcoming-playlist list. Reconciliation previously restarted at the first segment
not marked ready, including segments already consumed. With a one-segment window,
playing segment 1, buffering segment 2, refreshing policy, and consuming segment 2
refilled segment 1 instead of segment 3. This both misreported useful buffer depth
and could waste origin work after cache eviction.

Reconciliation and batch selection now exclude consumed primary segments.
Completions for fetches overtaken by playback also cannot repopulate that window.
Upcoming playlists retain their own sequence range; a lower sequence in a future
playlist is not treated as already played.

`SegmentPrefetchScheduler.reposition(to:)` is an additive public API. It validates
the destination against the active playlist, cancels the old scheduling generation,
resets the consumed cursor and readiness, and schedules from the destination.
It retains cache bytes but rechecks their residency, so cache eviction before a
rewind causes missing media to be fetched again. An unknown destination returns
false without changing the current window.

`ProxyHLSPlayer` observes its native player's consumed segment position. Backward
movement, including return to the first segment, repositions the scheduler. This
also covers adopters using AVPlayer's seek/loop controls directly. It does not
change playback intent, automatically play a paused player, or alter seek tolerances.

Regression coverage includes policy refresh after consumption, rewind after
cache eviction followed by forward playback, invalid destinations, and upcoming
playlists with lower sequence numbers. The policy-refresh test fails before the
fix with ready sequence 1 instead of 3.

## Transport diagnostic

`make benchmark BENCHMARK_ARGS=--loopback` runs four excluded warm-ups and twenty
validated URLSession responses for each of 128-byte and 256-KiB payloads. It prints
raw elapsed milliseconds as JSON and verifies status/body correctness. It is a
host microbenchmark, not AVPlayer startup, rendered-frame timing, network shaping,
or an assertion of an end-user speedup. Default TCP behavior is unchanged.

Performance conclusions require replaying the same rendered workload before and
after this fix; scheduler correctness tests alone do not establish a latency win.

## Finalized VOD publication reuse

A full-segment playlist explicitly marked VOD and ENDLIST has identical rewritten
bytes across prefetch and playback states. The player now retains the last
published playlist model and skips reconstructing/hashing that manifest when only
buffer state changes. The retained publication is invalidated at load/rendition
cleanup. Mutable timelines and playlists containing parts continue to rewrite.
A generation check prevents an old rewrite from updating publication bookkeeping
for a newer load. Integration coverage verifies segment availability after policy
changes and replacement with the correct content on the next load.

This removes redundant work by construction; it is not a claim that the remaining
player readiness or CPU regressions are resolved. Device profiling and paired
playback measurements are still required.

## Preserve plain media-playlist input

For unencrypted, finalized VOD media-playlist inputs with no master-level metadata
or alternate renditions, the native player now opens the rewritten media playlist
directly. This avoids an extra synthetic master request and a made-up bandwidth
attribute. The public master endpoint remains available for existing clients.
Actual master inputs, alternate renditions, encryption, live streams, and stitched
clips continue through the master route. Reload coverage checks both direct-media
selection and return to master routing for live content.
