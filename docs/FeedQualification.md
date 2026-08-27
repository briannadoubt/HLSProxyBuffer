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
| iOS UI | 14-item warmup plus 100 rapid accessibility navigations | Correct final item, decoded platform playback, predicted-warm first-frame p95 at or below 500 ms, cancellation at or below 250 ms, and bounded post-warmup resources |

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
