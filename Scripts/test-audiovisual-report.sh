#!/usr/bin/env bash
set -euo pipefail

# This tests rejection behavior only. These synthetic JSON inputs must never be
# published as qualification evidence for a media corpus or playback run.
REPORT_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hls-report-contract.XXXXXX")
trap 'rm -f "$REPORT_TEST_ROOT"/*.json; rmdir "$REPORT_TEST_ROOT"' EXIT
jq -n '{schemaVersion:1, qualificationKind:"real_audiovisual_feed_ui", passed:true, corpusVersion:"contract-test"}' > "$REPORT_TEST_ROOT/ui.json"
jq -n '{schemaVersion:1, qualificationKind:"real_audiovisual_native_decode", corpusVersion:"contract-test", evidence:[
  ["animation","liveAction"][] as $kind | ["360p","720p"][] as $rendition |
  {clipKind:$kind,rendition:$rendition,videoFrames:193,sampledFrames:8,distinctLumaSamples:8,
   pcmSamples:765824,audioRMSDBFS:-31,audioPeakDBFS:-12,videoDuration:8.021,audioDuration:7.977}]}' > "$REPORT_TEST_ROOT/decode.json"
jq -n '{schemaVersion:1, qualificationKind:"real_audiovisual_native_playback", passed:true, corpusVersion:"contract-test",
  decodedFrameCount:20,nativeAudioOwnershipViolationCount:0,nativeAudioTrackCheckCount:6,
  scenarioIDs:["360p_native_playback","720p_native_playback","revisit","focus_handoff","suspend_resume","retired_audio_teardown"]}' > "$REPORT_TEST_ROOT/renditions.json"
jq -n '{schemaVersion:1, qualificationKind:"real_audiovisual_native_playback", passed:true, corpusVersion:"contract-test",
  decodedFrameCount:20,nativeAudioOwnershipViolationCount:0,nativeAudioTrackCheckCount:0,
  scenarioIDs:["cold_empty_cache","new_engine_warm_disk","offline_warm_reuse","uncached_offline_failure","memory_pressure","poor_network_recovery","disk_eviction"]}' > "$REPORT_TEST_ROOT/cache.json"

compose() {
  local changed="${1:-none}"
  jq -n -e \
    --slurpfile ui "$REPORT_TEST_ROOT/$(if [ "$changed" = ui ]; then echo changed; else echo ui; fi).json" \
    --slurpfile decode "$REPORT_TEST_ROOT/$(if [ "$changed" = decode ]; then echo changed; else echo decode; fi).json" \
    --slurpfile renditions "$REPORT_TEST_ROOT/$(if [ "$changed" = renditions ]; then echo changed; else echo renditions; fi).json" \
    --slurpfile cache "$REPORT_TEST_ROOT/$(if [ "$changed" = cache ]; then echo changed; else echo cache; fi).json" \
    -f Scripts/compose-audiovisual-report.jq >/dev/null
}
reject() {
  local input="$1" mutation="$2"
  jq "$mutation" "$REPORT_TEST_ROOT/$input.json" > "$REPORT_TEST_ROOT/changed.json"
  if compose "$input" 2>/dev/null; then
    echo "Audiovisual report incorrectly accepted $input: $mutation" >&2
    exit 1
  fi
}
compose
reject ui '.passed = false'
reject decode '.evidence[0].audioRMSDBFS = -80'
reject decode '.evidence[0].pcmSamples = 0'
reject decode '.evidence[0].distinctLumaSamples = 1'
reject decode '.evidence[0].audioDuration = 6'
reject decode '.evidence[0].rendition = "720p"'
reject renditions '.nativeAudioTrackCheckCount = 0'
reject renditions '.nativeAudioOwnershipViolationCount = 1'
reject renditions '.scenarioIDs[0] = "revisit"'
reject cache '.scenarioIDs |= .[1:]'
reject cache '.corpusVersion = "wrong-corpus"'
echo "Audiovisual report contract: valid join and 11 rejection cases passed."
