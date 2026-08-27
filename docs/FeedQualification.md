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

The iOS UI test attaches `hls-feed-ui-qualification.json` to its result bundle.
`Scripts/run-ci.sh` places that bundle beside the JSON reports. GitHub Actions
uploads the directory with `if: always()`, preserving the failing measurement
instead of only reporting a red job.

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
