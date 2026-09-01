# Automatic feed release qualification

HLS-20 turns the automatic feed's product promises into merge-blocking,
machine-readable gates. The qualification uses only checked-in media and a
loopback origin, so network variability cannot disguise scheduling, ownership,
cache, or playback regressions.

## Gate matrix

| Layer | Workload | Required evidence |
| --- | --- | --- |
| Planner/coordinator | 532 observations across all standard paging, reversal, fling, oscillation, and sustained-scroll traces | Preparation concurrency, resident items, estimated bytes, cancellation acknowledgement, and stale-result bounds |
| Engine | 500 focus transitions | Player-pool bounds, unique leases, at least 99% successful handoffs, and zero remaining loads, observers, listeners, or players after teardown |
| Analytics scale | 100,000 correlated events plus two slow subscribers | Exact summaries and bounded timeline, queue, memory, task, subscriber, and drop accounting |
| Analytics delivery/privacy | Slow and offline exporters plus canonical/spooled payload scans | Priority shedding, bounded disk recovery, critical-summary survival, and no sensitive or unapproved identifiers |
| Analytics overhead | Alternating enabled/disabled local-fixture engine runs after warmup | No more than 5 ms first-frame p95 overhead and no more than two CPU percentage points |
| Production preparation | 100 local-origin transitions | Cold readiness at or below 250 ms, predicted-warm p95 at or below 50 ms, at least 90% revisit reuse, and cache/storage bounds |
| Source coverage | VOD, live/DVR, compatible stitched clips | Prepared resources, validated live window, and two-playlist stitched timeline |
| iOS UI | 14-item warmup plus 100 rapid accessibility navigations | Correct final item, decoded platform playback, predicted-warm first-frame p95 hard gate at or below 500 ms with release evidence at or below 400 ms, cancellation at or below 250 ms, and bounded post-warmup resources |

## Artifacts

The SwiftPM tests write the following JSON files when
`HLS_CI_ARTIFACT_DIR` is set:

- `hls-feed-coordinator-stress.json`
- `hls-feed-engine-endurance.json`
- `hls-feed-origin-readiness.json`
- `hls-feed-source-coverage.json`
- `hls-playback-analytics-scale-release.json`
- `hls-playback-analytics-recovery-release.json`
- `hls-playback-analytics-privacy-release.json`
- `hls-playback-analytics-overhead-release.json`

The iOS UI test attaches `hls-feed-ui-qualification.json` to its result bundle.
`Scripts/run-ci.sh` places that Release-mode bundle beside the JSON reports;
Address Sanitizer and Thread Sanitizer logs are stored in the same directory.
GitHub Actions uploads the directory with `if: always()`, preserving the
failing measurement instead of only reporting a red job.

Before HLS-31, the proxy-backed session published `.ready` as soon as its
playlist and buffer were installed. The feed engine consequently labeled that
lease warm even though AVPlayer could still be loading and decoding its media
pipeline; slower hosted runners exposed the gap as a 500 ms warm first-frame
p95. A loaded lease now waits for `AVPlayer` and `AVPlayerItem` readiness and
uses cancellable async `preroll(atRate:)` before becoming warm. Obsolete
navigation cancels the pending preroll with `cancelPendingPrerolls()`, so the
improvement moves real decode work into the predictive preparation window
without weakening the focus-to-platform-playback measurement or its 500 ms
hard gate.

The default bounded latency histogram includes both 400 ms and 500 ms bucket
boundaries. Hosted evidence can therefore distinguish the release target from
the unchanged hard ceiling instead of rounding every 251-500 ms sample up to
500 ms. The real paging flow also collects at least twenty settled warm decoded
starts, so its p95 remains a percentile under an isolated scheduler interruption
instead of collapsing to the maximum of a ten-sample run.

Prepared feed leases start with `playImmediately(atRate:)` after their successful
preroll. This skips AVPlayer's cold-start stall heuristic during a warm handoff;
the decoded-frame gate still requires an actual pixel buffer and advancing frame
timestamps, so entering the `.playing` state alone cannot pass real-media
qualification.

Timing evidence carries an explicit profile and limit. Controlled local or
dedicated-hardware release qualification uses the `release_reference` profile
and the 500 ms warm p95 ceiling. GitHub's shared macOS runners use the
`shared_runner` profile with a 1000 ms warm p95 ceiling because unrelated host
scheduling is not controlled there. Every ownership, decoded/advancing-frame,
audio, cancellation, cache, network, and resource bound remains identical and
merge-blocking in both profiles; the uploaded JSON records which timing ceiling
was applied. Set `HLS_CI_TIMING_PROFILE=shared-runner` only for shared-runner CI;
the CI harness carries this choice into Xcode UI tests as a Swift compilation
condition because hosted test runners do not reliably inherit shell variables.

## Reproducing the UI gate

Choose an installed iOS simulator and run:

```sh
xcodebuild \
  -project Demo/HLSProxyFeedDemo/HLSProxyFeedDemoApp.xcodeproj \
  -scheme HLSProxyFeedQualification \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  test
```

The scheme intentionally uses Release configuration. Regenerate the project
after editing `project.yml` with `xcodegen generate --spec
Demo/HLSProxyFeedDemo/project.yml`.

The tvOS simulator stage also uses Release, with `ENABLE_TESTABILITY=YES`
for the package's internal regression tests. Its cold/warm preparation limits
remain 250 ms/50 ms; unoptimized Debug timing is not a release-performance
measurement. Host Debug correctness and sanitizer gates remain separate.
