#!/usr/bin/env bash
# Fast device deploy for tuning on the physical iPhone.
#
#   tools/deploy-device.sh            # incremental build + install + launch
#   tools/deploy-device.sh --regen    # force-regenerate the signed project first
#
# The repo's project.yml is simulator-only (CODE_SIGNING_ALLOWED=NO). This script
# generates a *signed* Xcode project (team baked in) WITHOUT modifying the
# committed project.yml, then does incremental xcodebuild + devicectl install +
# launch. After the first (signing) generation it reuses the project, so each
# tweak is just a fast incremental compile.
#
# LOCAL ONLY — intentionally left untracked; not part of the candidate.
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

DEVICE="${MOZZ_DEVICE:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"   # Brando's iPhone
# Brandon's account is a member of paid team N8Z5T4AK3X (same team fastlane uses);
# automatic signing resolves under it. The keychain also has an orphaned personal
# cert (2U2G8XRS88) with NO logged-in account — do NOT use it (it fails with
# "No Account for Team 2U2G8XRS88").
TEAM="${MOZZ_TEAM:-N8Z5T4AK3X}"
BUNDLE=com.thatcube.Mozz

# Build for device with BETA Xcode (global default): it has the iOS 27 SDK and
# device support for the iOS 26.5 phone, and signs fine with the personal team.
# We deliberately do NOT force a DEVELOPER_DIR so it tracks the machine's active
# xcodebuild (beta); other agents' simulator builds are unaffected either way.
export DEVELOPER_DIR="${MOZZ_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

regen_signed() {
  echo "▸ Generating signed Xcode project (team $TEAM)…"
  # Temporarily flip signing on, regenerate, then restore project.yml so the
  # repo stays clean and simulator builds are unaffected.
  cp project.yml .project.yml.bak
  sed -i '' 's/CODE_SIGNING_REQUIRED: "NO"/CODE_SIGNING_REQUIRED: "YES"/' project.yml
  sed -i '' 's/CODE_SIGNING_ALLOWED: "NO"/CODE_SIGNING_ALLOWED: "YES"/' project.yml
  sed -i '' "s/    CODE_SIGN_STYLE: Automatic/    CODE_SIGN_STYLE: Automatic\n    DEVELOPMENT_TEAM: \"$TEAM\"/" project.yml
  rm -rf Mozz.xcodeproj
  tools/generate-project.sh >/dev/null
  mv .project.yml.bak project.yml
}

# Regenerate if asked, if the project is missing, or if it's still the
# simulator-only (unsigned) variant.
if [[ "${1:-}" == "--regen" ]] || [[ ! -d Mozz.xcodeproj ]] || \
   ! grep -q 'CODE_SIGNING_ALLOWED = YES' Mozz.xcodeproj/project.pbxproj 2>/dev/null; then
  regen_signed
fi

echo "▸ Building for device…"
set -o pipefail
xcodebuild -project Mozz.xcodeproj -scheme Mozz -configuration Debug \
  -destination "platform=iOS,id=$DEVICE" \
  -derivedDataPath .build/dd-device \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
  build \
  | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify --quiet || cat; }

APP=$(find .build/dd-device/Build/Products -name "Mozz.app" -type d | head -n1)
echo "▸ Installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "▸ Launching…"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
echo "✓ Deployed to device $DEVICE"
