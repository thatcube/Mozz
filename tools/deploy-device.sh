#!/usr/bin/env bash
# Fast device deploy for tuning on the physical iPhone.
#
#   tools/deploy-device.sh              # branch build: installs as a SEPARATE app
#                                       # "Mozz <branch>" so branches don't overwrite
#                                       # each other. No widget (see below).
#   MOZZ_WIDGETS=1 tools/deploy-device.sh   # canonical "Mozz" (com.thatcube.Mozz)
#                                           # WITH widgets — the real app / widget test
#                                           # build. Overwrites the canonical install.
#   tools/deploy-device.sh --regen      # force-regenerate the signed project first
#
# Per-branch identity: so many feature-branch builds can coexist on the device,
# a branch build gets a unique bundle id (com.thatcube.Mozz.<slug>) + display name
# ("Mozz <slug>"). The team WILDCARD profile signs any com.thatcube.* id headlessly
# — but ONLY without special entitlements. The App Group the widgets need requires
# an explicit per-id profile (a manual Xcode step), which would break this headless
# flow, so branch builds DROP the widget + app group. Use MOZZ_WIDGETS=1 (canonical
# id) when you actually want to see the widgets. `main` always builds canonical+widget.
#
# The repo's project.yml is simulator-only (CODE_SIGNING_ALLOWED=NO). This script
# generates a *signed* Xcode project (team baked in) WITHOUT modifying the
# committed project.yml, then does xcodebuild + devicectl install + launch.
#
# LOCAL ONLY — intentionally left untracked; not part of the candidate.
set -euo pipefail
cd "$(dirname "$0")/.."

export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:-'safe.bareRepository=all'}"

DEVICE="${MOZZ_DEVICE:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"   # Brando's iPhone
# Brandon's ONE team: "Brandon Moore" = N8Z5T4AK3X (all app profiles live here;
# the keychain cert is stamped with the free personal team 2U2G8XRS88 but is
# authorized under N8Z5T4AK3X, which is why signing works). Do NOT "fix" this to
# 2U2G8XRS88. See AGENTS.local.md -> "SIGNING".
TEAM="${MOZZ_TEAM:-N8Z5T4AK3X}"

# --- Per-branch identity -----------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
SLUG="$(echo "$BRANCH" | sed -E 's/^thatcube-//; s/[^A-Za-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
if [[ "$BRANCH" == "main" || "${MOZZ_WIDGETS:-}" == "1" || -z "$SLUG" ]]; then
  # Canonical build: real bundle id + widgets/app-group.
  VARIANT="canonical"
  BUNDLE="com.thatcube.Mozz"
  APP_LABEL="${MOZZ_APP_LABEL:-Mozz}"
else
  # Branch build: unique id + name, no widget (headless, coexists with others).
  VARIANT="branch"
  BUNDLE="com.thatcube.Mozz.${SLUG}"
  APP_LABEL="${MOZZ_APP_LABEL:-Mozz ${SLUG}}"
fi

# Build for device with BETA Xcode (global default): it has the iOS 27 SDK and
# device support for the iOS 26.5 phone. We deliberately do NOT force a
# DEVELOPER_DIR so it tracks the machine's active xcodebuild (beta).
export DEVELOPER_DIR="${MOZZ_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

# Strip the widget extension + app group from a working project.yml (branch
# builds only), so a unique bundle id signs with the wildcard profile headlessly.
strip_widget() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
# Drop the whole MozzWidget target (last block in the file).
text = text.split("\n  MozzWidget:")[0].rstrip() + "\n"
# Drop the app's widget dependency + app-group entitlements block.
text = text.replace("      - target: MozzWidget\n", "")
text = text.replace(
    "    entitlements:\n"
    "      path: App/Mozz/Mozz.entitlements\n"
    "      properties:\n"
    "        com.apple.security.application-groups:\n"
    "          - group.com.thatcube.Mozz\n",
    "")
open(path, "w").write(text)
PY
}

regen_signed() {
  echo "▸ Generating signed Xcode project (team $TEAM, $VARIANT: $BUNDLE)..."
  cp project.yml .project.yml.bak
  sed -i '' 's/CODE_SIGNING_REQUIRED: "NO"/CODE_SIGNING_REQUIRED: "YES"/' project.yml
  sed -i '' 's/CODE_SIGNING_ALLOWED: "NO"/CODE_SIGNING_ALLOWED: "YES"/' project.yml
  sed -i '' "s/    CODE_SIGN_STYLE: Automatic/    CODE_SIGN_STYLE: Automatic\n    DEVELOPMENT_TEAM: \"$TEAM\"/" project.yml
  if [[ "$VARIANT" == "branch" ]]; then
    strip_widget project.yml
    sed -i '' "s/        PRODUCT_BUNDLE_IDENTIFIER: com.thatcube.Mozz\$/        PRODUCT_BUNDLE_IDENTIFIER: ${BUNDLE}/" project.yml
    sed -i '' "s/        CFBundleDisplayName: Mozz\$/        CFBundleDisplayName: ${APP_LABEL}/" project.yml
  fi
  rm -rf Mozz.xcodeproj
  tools/generate-project.sh >/dev/null
  mv .project.yml.bak project.yml
}

# Regenerate if asked, if the project is missing/unsigned, or if the cached
# project's baked bundle id doesn't match the identity we want this run.
if [[ "${1:-}" == "--regen" ]] || [[ ! -d Mozz.xcodeproj ]] || \
   ! grep -q 'CODE_SIGNING_ALLOWED = YES' Mozz.xcodeproj/project.pbxproj 2>/dev/null || \
   ! grep -q "PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE};" Mozz.xcodeproj/project.pbxproj 2>/dev/null; then
  regen_signed
fi

echo "▸ Building for device ($APP_LABEL)..."
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
echo "▸ Launching..."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
echo "✓ Deployed '$APP_LABEL' ($BUNDLE) to device $DEVICE"
