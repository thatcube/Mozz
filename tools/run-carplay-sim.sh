#!/usr/bin/env bash
#
# Build, install and launch Mozz on an iOS Simulator with CarPlay enabled.
#
# Why this exists rather than just using tools/build-ios.sh:
#
#   * The CarPlay entitlement is only embedded when the binary is signed, and
#     build-ios.sh deliberately builds with CODE_SIGNING_ALLOWED=NO. This signs
#     ad-hoc ("-"), which the Simulator is happy with and which costs nothing.
#
# Afterwards, in Simulator.app: I/O -> External Displays -> CarPlay.
#
# NOTE: not every Xcode ships that menu — Xcode 27 beta's Simulator does not
# expose it. When it is missing, test on a real head unit instead; the device
# build carries the real entitlement and is the authoritative test anyway.
#
set -euo pipefail

cd "$(dirname "$0")/.."

# SwiftPM refuses to resolve inside a git worktree without this.
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"

DEVICE="${MOZZ_SIM_DEVICE:-iPhone 17 Pro}"
SCHEME="Mozz"
CONFIG="${MOZZ_CONFIG:-Debug}"
DERIVED="${MOZZ_DERIVED:-build/carplay}"

XCODEBUILD="xcodebuild"
if [ -d /Applications/Xcode-beta.app ]; then
  XCODEBUILD="env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild"
fi

echo "▸ Generating project…"
tools/generate-project.sh >/dev/null

echo "▸ Booting ${DEVICE}…"
UDID=$(xcrun simctl list devices available \
  | sed -n "s/^ *${DEVICE} (\([0-9A-F-]*\)).*/\1/p" | head -1)
if [ -z "$UDID" ]; then
  echo "✗ No available simulator named '$DEVICE'. Set MOZZ_SIM_DEVICE to one of:"
  xcrun simctl list devices available | sed -n 's/^ *\([^(]*\) (.*/  \1/p' | sort -u | head -20
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true

echo "▸ Building (ad-hoc signed so the CarPlay entitlement applies)…"
# shellcheck disable=SC2086
$XCODEBUILD \
  -project Mozz.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build 2>&1 | grep -Ev "^\s*$" | tail -30

APP="$DERIVED/Build/Products/$CONFIG-iphonesimulator/Mozz.app"
[ -d "$APP" ] || { echo "✗ No app at $APP"; exit 1; }

echo "▸ Checking the CarPlay entitlement…"
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "carplay-audio"; then
  echo "✓ com.apple.developer.carplay-audio present"
else
  echo "⚠ CarPlay entitlement missing from the simulator build."
  echo "  The Simulator strips entitlements it can't match to a profile, so this"
  echo "  can happen even though the device build is correct. Test in the car."
fi

echo "▸ Installing…"
xcrun simctl install "$UDID" "$APP"
echo "▸ Launching…"
xcrun simctl launch "$UDID" com.thatcube.Mozz >/dev/null || true

echo
echo "✓ Running on $DEVICE."
echo "  In Simulator.app choose:  I/O ▸ External Displays ▸ CarPlay"
