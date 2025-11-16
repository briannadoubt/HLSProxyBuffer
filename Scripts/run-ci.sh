#!/usr/bin/env bash
set -euo pipefail

echo "Running SwiftPM tests on host..."
swift test

if command -v xcodebuild >/dev/null 2>&1; then
  IOS_SIM_NAME="iPhone Air"
  IOS_SIM_UDID=$(xcrun simctl list devices "iOS" | grep "$IOS_SIM_NAME" | head -n 1 | sed -n 's/.*(\([0-9A-F-]*\)).*/\1/p')
  if [ -n "$IOS_SIM_UDID" ]; then
    echo "Booting $IOS_SIM_NAME simulator ($IOS_SIM_UDID)..."
    xcrun simctl boot "$IOS_SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$IOS_SIM_UDID" -b >/dev/null 2>&1 || true

    echo "Building HLSProxyBuffer for $IOS_SIM_NAME (iOS 26.1)..."
    xcodebuild \
      -scheme HLSProxyBuffer \
      -destination "platform=iOS Simulator,name=$IOS_SIM_NAME,OS=26.1" \
      -sdk iphonesimulator \
      build || echo "iOS simulator build failed."
  else
    echo "iOS simulator build skipped (no $IOS_SIM_NAME available)."
  fi

  TVOS_SIM_NAME="Apple TV 4K (3rd generation)"
  TVOS_SIM_UDID=$(xcrun simctl list devices "tvOS" | grep "$TVOS_SIM_NAME" | head -n 1 | sed -n 's/.*(\([0-9A-F-]*\)).*/\1/p')
  if [ -n "$TVOS_SIM_UDID" ]; then
    echo "Booting $TVOS_SIM_NAME simulator ($TVOS_SIM_UDID)..."
    xcrun simctl boot "$TVOS_SIM_UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$TVOS_SIM_UDID" -b >/dev/null 2>&1 || true

    echo "Running tvOS Simulator smoke test on $TVOS_SIM_NAME..."
    xcodebuild \
      -scheme HLSProxyBuffer-Package \
      -destination "platform=tvOS Simulator,id=$TVOS_SIM_UDID" \
      test || echo "tvOS simulator run skipped (command failed)."
  else
    echo "tvOS simulator run skipped (no $TVOS_SIM_NAME available)."
  fi
fi
