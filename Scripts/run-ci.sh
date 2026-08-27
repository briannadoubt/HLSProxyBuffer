#!/usr/bin/env bash
set -euo pipefail

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
swift test

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
    xcodebuild \
      -scheme HLSProxyBuffer \
      -destination "platform=iOS Simulator,id=$IOS_SIM_UDID" \
      -sdk iphonesimulator \
      build

    echo "Building the automatic SwiftUI feed demo for $IOS_SIM_NAME..."
    xcodebuild \
      -scheme HLSProxyFeedDemo \
      -destination "platform=iOS Simulator,id=$IOS_SIM_UDID" \
      -sdk iphonesimulator \
      build
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
      echo "Running tvOS Simulator smoke test on $TVOS_SIM_NAME..."
      xcodebuild \
        -scheme HLSProxyBuffer-Package \
        -destination "platform=tvOS Simulator,id=$TVOS_SIM_UDID" \
        test
    fi

  else
    echo "tvOS simulator run skipped (no $TVOS_SIM_NAME available)."
  fi
fi
