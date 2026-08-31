# Inputs are bounded aggregate reports, not media files or request histories.
def require($condition; $reason): if $condition then . else error($reason) end;
$ui[0] as $u | $decode[0] as $d | $renditions[0] as $r | $cache[0] as $c |
require($u.qualificationKind == "real_audiovisual_feed_ui" and $u.schemaVersion == 1 and $u.passed == true; "UI audiovisual qualification failed") |
require($d.qualificationKind == "real_audiovisual_native_decode" and $d.schemaVersion == 1; "missing native decode evidence") |
require([$d.evidence[] | .clipKind + "/" + .rendition] | sort == ["animation/360p", "animation/720p", "liveAction/360p", "liveAction/720p"]; "native decode coverage incomplete") |
require(all($d.evidence[]; .videoFrames > 0 and .sampledFrames == 8 and .distinctLumaSamples >= 4 and .pcmSamples > 0 and .audioRMSDBFS > -60 and .audioPeakDBFS > -40 and ((.videoDuration - .audioDuration) | fabs) <= 0.1); "native decode acceptance failed") |
require(all([$r, $c][]; .schemaVersion == 1 and .qualificationKind == "real_audiovisual_native_playback" and .passed == true and .decodedFrameCount > 0 and .nativeAudioOwnershipViolationCount == 0); "native playback qualification failed") |
require($u.corpusVersion != null and all([$d, $r, $c][]; .corpusVersion == $u.corpusVersion); "corpus versions do not agree") |
require($r.nativeAudioTrackCheckCount == 6 and ($r.scenarioIDs | sort) == (["360p_native_playback", "720p_native_playback", "revisit", "focus_handoff", "suspend_resume", "retired_audio_teardown"] | sort); "native rendition or audio-track coverage incomplete") |
require(($c.scenarioIDs | sort) == (["cold_empty_cache", "new_engine_warm_disk", "offline_warm_reuse", "uncached_offline_failure", "memory_pressure", "poor_network_recovery", "disk_eviction"] | sort); "native cache scenario coverage incomplete") |
{
  schemaVersion: 1,
  qualificationKind: "real_audiovisual_feed",
  corpusVersion: $u.corpusVersion,
  passed: true,
  nativeVideoDecodeCount: ($d.evidence | length),
  nativePCMDecodeCount: ($d.evidence | length),
  decodedPCMSampleCount: ([$d.evidence[].pcmSamples] | add),
  nativeAudioTrackCheckCount: ($r.nativeAudioTrackCheckCount + $c.nativeAudioTrackCheckCount),
  nativeDecode: $d,
  nativePlayback: [$r, $c],
  runtime: $u,
  boundaries: {
    videoEvidence: "decoded_pixel_buffers_not_display_scanout",
    audioEvidence: "native_PCM_and_player_eligibility_not_speaker_output",
    listeningCapture: "separate_manual_smoke_evidence_required",
    physicalDeviceQualification: "not_performed_by_simulator_CI"
  }
}
