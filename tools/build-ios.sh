#!/usr/bin/env bash
# Build the Mozz iOS app for the simulator (compile check; no signing needed).
# Regenerates the Xcode project first so it always reflects project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

"$(dirname "$0")/generate-project.sh"

DEST="${MOZZ_DEST:-generic/platform=iOS Simulator}"

echo "▸ Building Mozz for: $DEST"
set -o pipefail
xcodebuild \
  -project Mozz.xcodeproj \
  -scheme Mozz \
  -configuration Debug \
  -destination "$DEST" \
  CODE_SIGNING_ALLOWED=NO \
  build \
  | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }
echo "✓ Build succeeded."
