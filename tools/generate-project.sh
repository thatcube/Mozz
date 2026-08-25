#!/usr/bin/env bash
# Generate the Xcode project from project.yml with XcodeGen.
# The generated Mozz.xcodeproj is gitignored and regenerated on demand.
#
# Version scheme:
#   * MARKETING_VERSION (CFBundleShortVersionString) is CalVer from the build
#     date unless MOZZ_MARKETING_VERSION overrides it.
#   * CURRENT_PROJECT_VERSION (CFBundleVersion / build) is the git commit count
#     unless MOZZ_BUILD_NUMBER overrides it; dirty trees get a per-worktree suffix.
# Both come from tools/version-info.py, which the desktop build uses too.
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

eval "$(tools/version-info.py --format shell)"
BUILD="$MOZZ_RESOLVED_BUILD_NUMBER"
MARKETING="$MOZZ_RESOLVED_MARKETING_VERSION"

cp project.yml .project.yml.verbak
sed -i '' "s/CURRENT_PROJECT_VERSION: \"1\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
sed -i '' "s/^\( *\)MARKETING_VERSION: .*/\1MARKETING_VERSION: \"$MARKETING\"/" project.yml
restore_project_yml() { mv .project.yml.verbak project.yml; }
trap restore_project_yml EXIT

echo "▸ Generating Mozz.xcodeproj from project.yml (version $MARKETING, build $BUILD)…"
xcodegen generate
echo "✓ Done."
