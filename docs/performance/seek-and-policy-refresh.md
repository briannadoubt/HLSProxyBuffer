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
