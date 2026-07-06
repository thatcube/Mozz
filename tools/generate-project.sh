#!/usr/bin/env bash
# Generate the Xcode project from project.yml with XcodeGen.
# The generated Mozz.xcodeproj is gitignored and regenerated on demand.
#
# Version scheme:
#   * MARKETING_VERSION (CFBundleShortVersionString) is CalVer, set in project.yml
#     and bumped per release (e.g. 2026.7.6).
#   * CURRENT_PROJECT_VERSION (CFBundleVersion / build) is the git commit count,
#     baked in here so it auto-increments with history without editing project.yml.
#     (Release builds ship from main, whose commit count only grows -- monotonic
#     for TestFlight. Feature-branch dev builds may differ; that's fine locally.)
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftPM in a worktree/bare-repository host needs this to resolve packages.
export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# Bake the build number = commit count, restoring project.yml afterward so the
# committed file keeps its "1" fallback and the repo stays clean.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
RESTORE=0
if [[ "$BUILD" != "1" ]]; then
  cp project.yml .project.yml.verbak
  RESTORE=1
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"1\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
fi
restore_project_yml() { [[ "$RESTORE" == "1" ]] && mv .project.yml.verbak project.yml; }
trap restore_project_yml EXIT

echo "▸ Generating Mozz.xcodeproj from project.yml (build $BUILD)…"
xcodegen generate
echo "✓ Done."
