#!/usr/bin/env bash
# Generate the Xcode project from project.yml with XcodeGen.
# The generated Mozz.xcodeproj is gitignored and regenerated on demand.
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftPM in a worktree/bare-repository host needs this to resolve packages.
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "▸ Generating Mozz.xcodeproj from project.yml…"
xcodegen generate
echo "✓ Done."
