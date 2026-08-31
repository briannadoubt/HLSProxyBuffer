# Real audiovisual qualification (HLS-51)

The primary feed uses the `real-v1-886114cf0724` bundled NASA/Blender corpus.
Qualification keeps the existing synthetic performance fixture and adds native
decode, real-player, and actual vertical-swipe evidence. Completed HLS-1/HLS-34
results are not reinterpreted as audiovisual evidence.

## What is measured

- `firstFrameLatency` retains its existing meaning: focus request to
  `AVPlayer.timeControlStatus == .playing`. It is playback-start latency.
- `decodedFirstFrameLatency` is a separate distribution: focus request to the
  first image copied from `AVPlayerItemVideoOutput`. Lifecycle reactivation
  without a new focus request does not invent a latency sample.
- `decodedFrameCount` and `advancingDecodedFrameCount` count sampled images and
  strictly increasing image presentation timestamps, not all encoded frames.
- Each playback snapshot exposes `hasDecodedVideoFrame` and
  `hasAdvancingVideoFrames` for the current activation. Focus loss resets both.
- Native audio ownership samples actual `AVPlayer.isMuted` and `volume` for
  current player items, including prepared neighbors. An eligible player must
  match the focused/active lease; suspended and stopped engines have no owner.

These observations do not prove display scan-out, physical sound emission, or
perceptual lip sync. The output does not suppress AVPlayerLayer rendering.
There is at most one focused sampler: 16 ms polling until an image is available,
then 100 ms. Sampling stops synchronously on focus loss/suspension. Each bounded
resident native player lease retains its prepared output while warm; retirement
detaches it. There is at most one output per player (three in the short-form
preset), but only the focused output is sampled. Pixel buffers and per-frame
histories are never retained. Telemetry owns twelve
fixed paths, eight bounded histograms per path, and bounded newest-event streams.
Older JSON snapshots decode new fields as `nil`, not invented evidence.

The demo host configures its own playback/movie-playback audio session on iOS,
tvOS, and visionOS, activates it before foreground playback, and deactivates after
pausing on inactivity/background/stop. Activation failures remain visible and
leave playback suspended. Background cold starts and warming do not activate
audio. The reusable engine does not change an adopter's global audio session.

HLS-67 additionally preserves a muted feed lease across delayed native audio
property notifications. Under local TSan, a former focused player was observed
paused but unmuted at volume 1 after the engine had applied mute/volume 0; KVO
stacks identified a later AVFCore notification. A feed-only guard observes the
two properties, reasserts mute requirements without starting playback, and
coalesces off-main callbacks into at most one main-queue correction. Standalone
players have no such guard. Unit regressions inject late changes directly;
native rendition/handoff tests check actual players and cumulative ownership.

Native audio tracks must also be enabled at all six 360p/720p focus/revisit
checkpoints, sampled after advancing decoded frames. Sampling immediately after
muted preroll can still report a disabled track before playback activates it;
mere track presence or preroll state is not proof of enabled audio playback.

## Native tests

`FeedDemoNativeDecodeTests` assembles temporary files from the exact committed
initialization and media fragments, one bounded resource at a time. It does not
download or bundle another corpus. AVAssetReader independently decodes NASA and
Blender examples at both 360p/720p, checks dimensions/stereo 48 kHz audio, samples
eight luma signatures, and requires at least four different signatures. PCM must
be nonempty with RMS above -60 dBFS and peak above -40 dBFS. Decoded A/V duration
mismatch must remain at most 100 ms.

AVFoundation may synthesize a presentation sample at time zero before the first
encoded PTS (21 ms here), and decoded video sample durations can be invalid.
Timing therefore uses decoded PTS plus the track's loaded minimum frame duration;
native sample count is not assumed equal to encoded packet count. Row padding is
excluded from luma hashes. Decode readers have bounded loops and always cancel.

`FeedDemoAudiovisualIntegrationTests` uses the real proxy/cache/player path,
explicit rendition playlists, advancing output and playback time, and selected
native audio tracks. It checks handoff/revisit, suspension/resumption, teardown,
empty-cache startup, a new engine with warm disk and an offline origin, uncached
offline failure, poor-network recovery, memory pressure, and disk-budget eviction.
Warm-prefix reuse is not a claim that the entire asset is downloaded for offline
playback. Hosted CI explicitly runs these bounded native tests outside sanitizers
before starting simulator performance work.

## Real swipes and reports

The primary XCUITest uses actual paging gestures, including fast flings/reversal,
offline revisit, throttling, pressure, and home/foreground. Settled pages must
have advancing decoded frames as well as aligned focus/active/audio ownership.
The report preserves the 500 ms warm playback-start p95 and 250 ms cancellation
maximum and adds a separate 500 ms warm decoded-frame p95 check. Cold decoded
latency and stalls are reported separately. All cache, player/proxy, and
file-backed origin payload budgets remain unchanged.

`Scripts/compose-audiovisual-report.jq` joins native decode, native playback, and
real-swipe reports only when their corpus versions agree and every input passes.
The resulting `hls-real-audiovisual-feed.json` uses schema 1 and kind
`real_audiovisual_feed`. Reports contain bounded aggregate counts/distributions,
not source URLs, request histories, headers, or user identifiers. Failure JSON is
attached before UI pass assertions.

HLS-72 selects exported attachments by parsed root report kind, not text matches
inside nested reports or UUID filename order. Selection requires exactly one
schema-1 envelope with a Boolean result, then the existing pass gate validates
it. A failed report remains selected and fails the gate; it is not skipped in
favor of another report. Contract tests cover nested kinds, reversed ordering,
paths with spaces, missing/ambiguous reports, invalid envelopes, malformed JSON,
and multiple JSON documents in one attachment.

HLS-69 requires the UI gate to decode the root schema version, report kind, and
Boolean `passed` field. A successful nested vertical report cannot override a
failed audiovisual envelope. A focused regression rejects root failure with
nested success, missing/wrongly typed fields, unsupported versions, wrong kinds,
arrays, and malformed JSON. Hosted run 33361191832 exposed this assertion bug:
the real audiovisual report exceeded the unchanged warm playback-start gate even
though the nested vertical report passed. That run is not passing qualification.

HLS-70 prepares each lease's video output before the player's native preroll.
Warm handoff starts sampling the already-prepared output without attaching or
removing outputs during activation. Native tests check output identity across
revisit, the existing player-pool bound, exactly one active sampler, suspension,
and complete retirement. Unit checks distinguish prepared, sampling, paused, and
retired observer lifetimes. Neither the `.playing` definition nor the decoded-image
focus timestamp changes, and the player's wait/preroll behavior is unchanged.

This supersedes an intermediate ordering-only correction. Local probes measured
about 25–34 ms of attachment work before `play()` on several real handoffs; moving
it after `play()` passed both UI iterations but moved decoded-image p95 from
100 ms to 400 ms. That tradeoff was not accepted as an overall improvement.
Preparation now includes the output configuration, rather than moving it from
one handoff measurement into the other. These local probes alone do not uniquely
explain the original hosted failure; full hosted qualification remains required.

HLS-73 covers a second completion order: the neighbor may still be loading when
focus changes and finish priming while expanded focused preparation is pending.
Both initial-load completion and a later ready-state notification now reconcile
the newly primed current focus with the accepted working set before activation.
Source identity, lease ownership, retirement, suspension, and current-focus
checks remain mandatory. Held-task regressions reproduce the old generation
barrier for both completion orders and verify that reversal cannot reclaim focus.
This does not change warm/cold attribution, timestamps, or performance gates.
Hosted run 33367848192 failed real warm playback/decoded latency despite local
passes; that aggregate result alone does not attribute both slow samples to this
race. Final hosted verification is required after the correction.

Hosted run 33370696812 still exceeded the unchanged warm gates after that fix
(741 ms playing and 587 ms decoded maxima). Diagnostic `playbackStartStages`
therefore splits successful starts into focus-to-activation wait, synchronous
activation work, native play-to-playing time, and native-callback delivery to the
main actor. Four additional fixed histograms per path retain no item IDs or
navigation histories. Aggregation follows the original end-to-end sample, which
keeps its timestamp, attribution, and gates; missing stage evidence never removes
an end-to-end sample. Native callback time is captured before hopping actors.
An older export decodes the additional stage field as nil. These diagnostics are
not a fix or a claim that any one stage caused the hosted failure.

Hosted run 33375049548 passed real audiovisual paging (500 ms playing and
400 ms decoded p95 buckets), but synthetic stress still failed its unchanged
500 ms gate with 118 warm samples in the 1000 ms p95 bucket. The synthetic
report now also exports `playbackStartDiagnostics` (schema 1): all twelve fixed
paths, their original start distributions, and the same four timing stages.
Older reports decode this optional envelope as nil. Reports are capped at
64 KiB; no navigation history is retained. The gate still reads the original
end-to-end distribution, never the diagnostic stage counts or intervals.

HLS-71 gives both UI qualification launch modes a typed `freshQualification`
cache scope. A worker prepares one reserved `HLSProxyBuffer-UIQualification`
directory before constructing the engine; repeated runs reset only that directory.
The engine still receives its normal typed disk-cache policy and canonical URLs,
and revisits/offline reuse within the run use real cached bytes. This establishes
an empty-cache starting condition for adverse-network work even if previous demo
launches warmed every clip. Normal launches retain the ordinary persistent cache
without clearing it. Native integration separately verifies warm-disk cold launch
and offline reuse across engine instances. File-system regressions check that the
qualification reset preserves ordinary cache bytes and does not accumulate new
namespaces or create anything for the persistent scope.

## Stable-runtime resource teardown (HLS-74)

Hosted run 33378556362 passed all five iOS UI tests and both unchanged warm
latency gates, then aborted four synchronous tvOS 26.2 teardown tests. The same
four failures reproduced on iOS 26.1. Native crash stacks identify
`TaskLocal::StopLookupScope` freeing an invalid pointer through
`swift_task_deinitOnExecutorImpl`, not an AVFoundation buffer double-free.
This matches the [upstream Swift runtime fix](https://github.com/swiftlang/swift/pull/85204)
and [older-runtime report](https://github.com/swiftlang/swift/issues/88036).
Two additional synchronous tests reproduce the same failure in the analytics
collector and legacy metric source.

All four resource owners now use ordinary deinitializers and transfer separate,
main-actor-isolated lifetime objects to cleanup. Main-thread release performs
cleanup synchronously; off-main last release enqueues one main-queue cleanup
without escaping the dying owner or claiming unchecked Sendable conformance.
Explicit stop remains synchronous and idempotent. Original synchronous tests
remain in place, with additional off-main release coverage for observer removal,
sampler release, metric-source stop, and stream termination. No playback behavior,
measurement timestamp, sample attribution, or performance limit changes.

The CI harness now stores the tvOS result bundle in the uploaded artifact
directory, outside temporary DerivedData cleanup, so future failures retain
their diagnostics. Final-head hosted verification and merge remain required.

## Listening and device boundaries

Native PCM decode proves the packaged recorded soundtrack is decodable and
non-silent. Selected audio tracks and mute/volume ownership prove eligibility.
Neither substitutes for listening to actual app output. XCTest simulator movies
may contain video only; do not add source audio to such a movie and call it a
playback recording. ReplayKit does not support this AVPlayer capture path.

An isolated app-output listening capture is a separate smoke check. Capture only
the verified demo audio process, never all-system audio or a microphone; obtain
human direction if the required OS permission or process isolation is unavailable.
Physical-device speakers, route changes/headphones, silent-switch behavior,
subjective A/V sync, energy/thermals, and hardware decoding remain separate device
qualification and must not be claimed from simulator CI.

On 2026-08-31, after explicit macOS Audio Capture approval, a private process tap
captured eight seconds of the verified simulator demo's output (stereo 48 kHz
PCM; no microphone or system mix). The maintainer listened to the actual-output
recording and confirmed the audio was fine. Together with the separately
inspected moving NASA playback video, this completes the simulator listening
smoke only; it does not establish synchronized-capture or physical-device results.
The first temporary recorder attempt reached capture but failed to write its
interleaved buffer using a deinterleaved file-processing format. Matching the
file's processing format to the tap buffer corrected the recorder, not the app.

References: [AVAssetReaderTrackOutput](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput),
[AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput),
[Core Audio process taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).
