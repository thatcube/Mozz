#!/usr/bin/env bash
# Run the MozzKit unit-test suite.
#
#   tools/run-tests.sh              # fast: all unit tests on the host toolchain
#   tools/run-tests.sh --sim        # run the suite on an iOS Simulator
#   tools/run-tests.sh --filter X   # pass-through filter (host mode)
#
# The host path is the fast inner loop: `swift test` only compiles targets that
# a test target depends on, so the iOS-only app module (MozzApp) is never built,
# and every logic layer (backend abstraction, DB/FTS, sync, playback queue,
# downloads/offline) is macOS-clean and runs without booting a simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

MODE="host"
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) MODE="sim"; shift ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

if [[ "$MODE" == "sim" ]]; then
  DEST="${MOZZ_DEST:-platform=iOS Simulator,name=Mozz iPhone}"
  echo "▸ Testing MozzKit on: $DEST"
  set -o pipefail
  xcodebuild test \
    -scheme MozzKit-Package \
    -destination "$DEST" \
    CODE_SIGNING_ALLOWED=NO \
    | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }
else
  echo "▸ Testing MozzKit on the host toolchain…"
  swift test "${EXTRA[@]}"
fi
echo "✓ Tests passed."
