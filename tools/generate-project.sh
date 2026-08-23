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
# Append rather than default-assign: the environment may already inject other
# params (e.g. credential helpers), in which case a ':-' default never applies
# and SwiftPM resolve fails with "Couldn't get the list of tags".
[[ "${GIT_CONFIG_PARAMETERS:-}" == *safe.bareRepository* ]] || \
  export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+${GIT_CONFIG_PARAMETERS} }'safe.bareRepository=all'"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# Bake the build number, restoring project.yml afterward so the committed file
# keeps its "1" fallback and the repo stays clean.
#
# MOZZ_BUILD_NUMBER lets fastlane pin the number instead: TestFlight requires
# each upload to be strictly higher than the last, and the commit count isn't
# that -- it can stall or go backwards across branches. Ship builds therefore
# derive it from TestFlight itself and pass it in here.
BUILD="${MOZZ_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# MOZZ_MARKETING_VERSION likewise pins CFBundleShortVersionString, so a release
# can't ship a binary whose version disagrees with its App Store record.
MARKETING="${MOZZ_MARKETING_VERSION:-}"

RESTORE=0
if [[ "$BUILD" != "1" || -n "$MARKETING" ]]; then
  cp project.yml .project.yml.verbak
  RESTORE=1
fi
if [[ "$BUILD" != "1" ]]; then
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"1\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
fi
if [[ -n "$MARKETING" ]]; then
  sed -i '' "s/^\( *\)MARKETING_VERSION: .*/\1MARKETING_VERSION: \"$MARKETING\"/" project.yml
fi
restore_project_yml() { if [[ "$RESTORE" == "1" ]]; then mv .project.yml.verbak project.yml; fi; }
trap restore_project_yml EXIT

echo "▸ Generating Mozz.xcodeproj from project.yml (build $BUILD${MARKETING:+, version $MARKETING})…"
xcodegen generate
echo "✓ Done."
