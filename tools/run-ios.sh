#!/usr/bin/env bash
# Build, install, and launch Mozz on an iOS Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

UDID="$("$(dirname "$0")/bootstrap-sim.sh")"
"$(dirname "$0")/generate-project.sh"

echo "▸ Building + installing Mozz on simulator ${UDID} ..."
set -o pipefail
xcodebuild \
  -project Mozz.xcodeproj \
  -scheme Mozz \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath .build/dd-ios \
  CODE_SIGNING_ALLOWED=NO \
  build \
  | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }

APP_PATH=$(find .build/dd-ios/Build/Products -name "Mozz.app" -type d | head -n1)
echo "▸ App: $APP_PATH"
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl launch "$UDID" com.thatcube.Mozz
echo "✓ Launched Mozz (com.thatcube.Mozz) on $UDID"
