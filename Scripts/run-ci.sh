#!/usr/bin/env bash
set -euo pipefail

QUALIFICATION_ARTIFACT_DIR="${HLS_CI_ARTIFACT_DIR:-$PWD/ci-artifacts}"
mkdir -p "$QUALIFICATION_ARTIFACT_DIR"
export HLS_CI_ARTIFACT_DIR="$QUALIFICATION_ARTIFACT_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to validate feed qualification reports"
  exit 1
fi
bash Scripts/test-audiovisual-report.sh
bash Scripts/test-report-selection.sh

CI_DERIVED_DATA_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hlsproxy-ci-derived.XXXXXX")

remove_derived_data() {
  local path="$1"
  case "$path" in
    "$CI_DERIVED_DATA_ROOT"/*)
      rm -rf -- "$path"
      ;;
    *)
      echo "Refusing to remove DerivedData outside $CI_DERIVED_DATA_ROOT: $path"
      return 1
      ;;
  esac
}

cleanup_ci_storage() {
  case "$CI_DERIVED_DATA_ROOT" in
    "${TMPDIR:-/tmp}"/hlsproxy-ci-derived.*)
      rm -rf -- "$CI_DERIVED_DATA_ROOT"
      ;;
    *)
      echo "Refusing to remove unexpected CI storage root: $CI_DERIVED_DATA_ROOT"
      ;;
  esac
}

trap cleanup_ci_storage EXIT

wait_for_simulator_boot() {
  local udid="$1"
  local timeout="${2:-180}"
  local poll=5
  local waited=0
  echo "Waiting for simulator $udid to boot (timeout ${timeout}s)..."
  local state
  while [ "$waited" -lt "$timeout" ]; do
    state=$(xcrun simctl list devices | grep "$udid" || true)
    if echo "$state" | grep -q "(Booted)"; then
      echo "Simulator $udid is booted."
      return 0
    fi
    sleep "$poll"
    waited=$((waited + poll))
  done
  echo "Timed out waiting for simulator $udid to boot."
  return 1
}

echo "Running SwiftPM tests on host..."
echo "Running analytics qualification in Release configuration..."
HLS_ANALYTICS_QUALIFICATION_CONFIGURATION=release \
  swift test -c release \
    --filter 'PlaybackAnalytics(Qualification|Performance)Tests'

echo "Running the remaining SwiftPM tests on host..."
swift test \
  --skip 'PlaybackAnalyticsQualificationTests' \
  --skip 'PlaybackAnalyticsPerformanceTests'

# These bounded real-media AVFoundation scenarios are explicitly qualified on
# the host outside sanitizer runs, before any simulator performance workload.
RUN_PROXY_AV_TESTS=1 swift test --filter FeedDemoAudiovisualIntegrationTests

FEED_QUALIFICATION_REPORT="$QUALIFICATION_ARTIFACT_DIR/hls-feed-qualification.json"
if [ ! -s "$FEED_QUALIFICATION_REPORT" ]; then
  echo "Missing feed qualification report: $FEED_QUALIFICATION_REPORT"
  exit 1
fi
echo "Feed qualification report: $FEED_QUALIFICATION_REPORT"

# The simulator builds use Xcode's own package products, so the SwiftPM
# intermediates from the host/sanitizer gates only consume runner storage now.
# Reclaim them before Xcode creates multiple platform SDK/module caches.
swift package clean
echo "Storage before simulator qualification:"
df -h "$PWD" "$CI_DERIVED_DATA_ROOT"

if command -v xcodebuild >/dev/null 2>&1; then
  IOS_SIM_NAME="iPhone Air"
  IOS_SIM_UDID=$(xcrun simctl list devices "iOS" | grep "$IOS_SIM_NAME" | head -n 1 | sed -n 's/.*(\([0-9A-F-]*\)).*/\1/p' || true)
  if [ -n "$IOS_SIM_UDID" ]; then
    echo "Booting $IOS_SIM_NAME simulator ($IOS_SIM_UDID)..."
    xcrun simctl boot "$IOS_SIM_UDID" >/dev/null 2>&1 || true
    if ! wait_for_simulator_boot "$IOS_SIM_UDID" 300; then
      echo "Failed to boot $IOS_SIM_NAME simulator."
      exit 1
    fi

    echo "Building HLSProxyBuffer for $IOS_SIM_NAME..."
    IOS_PACKAGE_DERIVED_DATA="$CI_DERIVED_DATA_ROOT/ios-package"
    xcodebuild \
      -scheme HLSProxyBuffer \
      -destination "platform=iOS Simulator,id=$IOS_SIM_UDID" \
      -sdk iphonesimulator \
      -derivedDataPath "$IOS_PACKAGE_DERIVED_DATA" \
      ONLY_ACTIVE_ARCH=YES \
      build
    remove_derived_data "$IOS_PACKAGE_DERIVED_DATA"

    echo "Building the automatic SwiftUI feed demo for $IOS_SIM_NAME..."
    FEED_DEMO_DERIVED_DATA="$CI_DERIVED_DATA_ROOT/feed-demo"
    xcodebuild \
      -scheme HLSProxyFeedDemo \
      -destination "platform=iOS Simulator,id=$IOS_SIM_UDID" \
      -sdk iphonesimulator \
      -derivedDataPath "$FEED_DEMO_DERIVED_DATA" \
      ONLY_ACTIVE_ARCH=YES \
      build

    echo "Running the Release-mode automatic feed UI qualification on $IOS_SIM_NAME..."
    UI_RESULT_BUNDLE="$QUALIFICATION_ARTIFACT_DIR/HLSProxyFeedQualification-$(date +%s).xcresult"
    xcodebuild \
      -project Demo/HLSProxyFeedDemo/HLSProxyFeedDemoApp.xcodeproj \
      -scheme HLSProxyFeedQualification \
      -destination "platform=iOS Simulator,id=$IOS_SIM_UDID" \
      -resultBundlePath "$UI_RESULT_BUNDLE" \
      -derivedDataPath "$FEED_DEMO_DERIVED_DATA" \
      ONLY_ACTIVE_ARCH=YES \
      test

    echo "Exporting the real vertical-feed UI qualification report..."
    UI_ATTACHMENT_DIR="$CI_DERIVED_DATA_ROOT/feed-ui-attachments"
    xcrun xcresulttool export attachments \
      --path "$UI_RESULT_BUNDLE" \
      --output-path "$UI_ATTACHMENT_DIR"
    VERTICAL_REPORT_SOURCE=$(bash Scripts/select-qualification-report.sh \
      vertical_paging_ui "$UI_ATTACHMENT_DIR"/*.json)
    VERTICAL_REPORT="$QUALIFICATION_ARTIFACT_DIR/hls-feed-vertical-ui-qualification.json"
    cp "$VERTICAL_REPORT_SOURCE" "$VERTICAL_REPORT"
    if ! jq -e \
      '.qualificationKind == "vertical_paging_ui" and .passed == true' \
      "$VERTICAL_REPORT" >/dev/null; then
      echo "The real vertical-feed UI qualification did not pass: $VERTICAL_REPORT"
      exit 1
    fi
    echo "Vertical-feed UI qualification report: $VERTICAL_REPORT"
    AUDIOVISUAL_SOURCE=$(bash Scripts/select-qualification-report.sh \
      real_audiovisual_feed_ui "$UI_ATTACHMENT_DIR"/*.json)
    cp "$AUDIOVISUAL_SOURCE" "$QUALIFICATION_ARTIFACT_DIR/hls-real-audiovisual-ui.json"
    jq -n -e \
      --slurpfile ui "$AUDIOVISUAL_SOURCE" \
      --slurpfile decode "$QUALIFICATION_ARTIFACT_DIR/hls-real-native-decode.json" \
      --slurpfile renditions "$QUALIFICATION_ARTIFACT_DIR/hls-real-native-renditions.json" \
      --slurpfile cache "$QUALIFICATION_ARTIFACT_DIR/hls-real-native-cache.json" \
      -f Scripts/compose-audiovisual-report.jq \
      > "$QUALIFICATION_ARTIFACT_DIR/hls-real-audiovisual-feed.json"
    remove_derived_data "$FEED_DEMO_DERIVED_DATA"
  else
    echo "iOS simulator build skipped (no $IOS_SIM_NAME available)."
  fi

  TVOS_SIM_NAME="Apple TV 4K (3rd generation)"
  TVOS_SIM_UDID=$(xcrun simctl list devices "tvOS" | grep "$TVOS_SIM_NAME" | head -n 1 | sed -n 's/.*(\([0-9A-F-]*\)).*/\1/p' || true)
  if [ -n "$TVOS_SIM_UDID" ]; then
    echo "Booting $TVOS_SIM_NAME simulator ($TVOS_SIM_UDID)..."
    xcrun simctl boot "$TVOS_SIM_UDID" >/dev/null 2>&1 || true
    if ! wait_for_simulator_boot "$TVOS_SIM_UDID" 300; then
      echo "tvOS simulator boot timed out; skipping tvOS smoke test."
    else
      echo "Running Release tvOS Simulator qualification on $TVOS_SIM_NAME..."
      TVOS_DERIVED_DATA="$CI_DERIVED_DATA_ROOT/tvos-package"
      TVOS_RESULT_BUNDLE="$QUALIFICATION_ARTIFACT_DIR/HLSProxyTVOSQualification-$(date +%s).xcresult"
      xcodebuild \
        -scheme HLSProxyBuffer-Package \
        -configuration Release \
        -destination "platform=tvOS Simulator,id=$TVOS_SIM_UDID" \
        -resultBundlePath "$TVOS_RESULT_BUNDLE" \
        -derivedDataPath "$TVOS_DERIVED_DATA" \
        ONLY_ACTIVE_ARCH=YES \
        ENABLE_TESTABILITY=YES \
        -skip-testing:ProxyPlayerKitTests/PlaybackAnalyticsPerformanceTests \
        test
      remove_derived_data "$TVOS_DERIVED_DATA"
    fi

  else
    echo "tvOS simulator run skipped (no $TVOS_SIM_NAME available)."
  fi
fi

echo "Storage after simulator qualification:"
df -h "$PWD" "$CI_DERIVED_DATA_ROOT"
