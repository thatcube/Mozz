#!/usr/bin/env bash
# Fast device deploy for tuning on the physical iPhone / iPad.
#
#   tools/deploy-device.sh              # iPhone (default). Branch build: installs
#                                       # as a SEPARATE app "Mozz <branch>" so
#                                       # branches don't overwrite each other.
#   tools/deploy-device.sh --ipad       # iPad only
#   tools/deploy-device.sh --iphone     # iPhone only (the default)
#   tools/deploy-device.sh --all        # both iPhone and iPad
#   tools/deploy-device.sh --build-only # compile, do not install
#   tools/deploy-device.sh --no-build   # reinstall the last built app
#   tools/deploy-device.sh --regen      # force-regenerate the signed project first
#   MOZZ_WIDGETS=1 tools/deploy-device.sh   # canonical "Mozz" (com.thatcube.Mozz)
#                                           # WITH widgets — the real app / widget
#                                           # test build. Overwrites the canonical.
#
# The app is universal (TARGETED_DEVICE_FAMILY "1,2"), so ONE build installs on
# both devices — --all builds once and installs twice.
#
# Per-branch identity: so many feature-branch builds can coexist on a device, a
# branch build gets a unique bundle id (com.thatcube.Mozz.<slug>) + display name
# ("Mozz <slug>"). The team WILDCARD profile signs any com.thatcube.* id
# headlessly — but ONLY without special entitlements. The App Group the widgets
# need requires an explicit per-id profile (a manual Xcode step), which would
# break this headless flow, so branch builds DROP the widget + app group. Use
# MOZZ_WIDGETS=1 (canonical id) when you actually want the widgets. `main`
# always builds canonical+widget.
#
# The repo's project.yml is simulator-only (CODE_SIGNING_ALLOWED=NO). This script
# generates a *signed* Xcode project (team baked in) WITHOUT modifying the
# committed project.yml, then does xcodebuild + a verified devicectl install.
set -euo pipefail
cd "$(dirname "$0")/.."

# Append rather than default-assign: the environment may already inject other
# params (e.g. credential helpers), in which case a ':-' default never applies
# and SwiftPM resolve fails with "Couldn't get the list of tags".
[[ "${GIT_CONFIG_PARAMETERS:-}" == *safe.bareRepository* ]] || \
  export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+${GIT_CONFIG_PARAMETERS} }'safe.bareRepository=all'"

IPHONE_ID="${MOZZ_IPHONE_ID:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"   # Brando's iPhone
IPAD_ID="${MOZZ_IPAD_ID:-D1EB8B46-3CEC-5F68-BCDA-B1C9E0E40600}"       # Brando's iPad
# Brandon's ONE team: "Brandon Moore" = N8Z5T4AK3X (all app profiles live here;
# the keychain cert is stamped with the free personal team 2U2G8XRS88 but is
# authorized under N8Z5T4AK3X, which is why signing works). Do NOT "fix" this to
# 2U2G8XRS88. See AGENTS.local.md -> "SIGNING".
TEAM="${MOZZ_TEAM:-N8Z5T4AK3X}"

DEPLOY_IPHONE=1
DEPLOY_IPAD=0
BUILD_ONLY=0
NO_BUILD=0
REGEN=0

for arg in "$@"; do
  case "$arg" in
    --iphone)     DEPLOY_IPHONE=1; DEPLOY_IPAD=0 ;;
    --ipad)       DEPLOY_IPHONE=0; DEPLOY_IPAD=1 ;;
    --all|--both) DEPLOY_IPHONE=1; DEPLOY_IPAD=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    --no-build)   NO_BUILD=1 ;;
    --regen)      REGEN=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# Back-compat: MOZZ_DEVICE pins a single explicit device and wins over the flags.
if [[ -n "${MOZZ_DEVICE:-}" ]]; then
  IPHONE_ID="$MOZZ_DEVICE"; DEPLOY_IPHONE=1; DEPLOY_IPAD=0
fi

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
# device support for the iOS 26.x devices.
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
# Drop the app's widget dependency.
text = text.replace("      - target: MozzWidget\n", "")
# Drop the app target's whole `entitlements:` block, whatever is in it.
#
# Structural rather than a literal string match on purpose: this used to spell
# out the app-group lines verbatim, so the moment another capability was added
# (CarPlay) the match silently failed, the entitlements survived into a
# wildcard-signed branch build, and provisioning failed with no clue why.
lines = text.split("\n")
out, skipping = [], False
for line in lines:
    if skipping:
        # The block ends at the next line indented no deeper than `entitlements:`.
        if line.strip() and not line.startswith("      "):
            skipping = False
        else:
            continue
    if line == "    entitlements:":
        skipping = True
        continue
    out.append(line)
open(path, "w").write("\n".join(out))
PY
}

regen_signed() {
  echo "▸ Generating signed Xcode project (team $TEAM, $VARIANT: $BUNDLE)..."
  cp project.yml .project.yml.bak
  # Always restore the committed project.yml, even if generation fails partway.
  trap 'mv -f .project.yml.bak project.yml 2>/dev/null || true' EXIT
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
  trap - EXIT
}

# Regenerate if asked, if the project is missing/unsigned, or if the cached
# project's baked bundle id doesn't match the identity we want this run.
if [[ "$REGEN" == "1" ]] || [[ ! -d Mozz.xcodeproj ]] || \
   ! grep -q 'CODE_SIGNING_ALLOWED = YES' Mozz.xcodeproj/project.pbxproj 2>/dev/null || \
   ! grep -q "PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE};" Mozz.xcodeproj/project.pbxproj 2>/dev/null; then
  regen_signed
fi

# --- Build destination -------------------------------------------------------
# Build against a CONCRETE device rather than `generic/platform=iOS`. With a
# generic destination xcodebuild has no target device to provision for, so
# -allowProvisioningUpdates can hand back a profile that doesn't cover the device
# we're installing on — which surfaces later as the famously unhelpful
#   Failed to install embedded profile ... 0xe8008012
# Naming the real device makes Xcode provision for it. (Learned in Plozz.)
TARGETS=()   # "label:coredevice-id" pairs, in install order
[[ "$DEPLOY_IPHONE" == "1" ]] && TARGETS+=("iPhone:$IPHONE_ID")
[[ "$DEPLOY_IPAD"   == "1" ]] && TARGETS+=("iPad:$IPAD_ID")

# Hardware UDIDs (what a provisioning profile lists) for the pre-flight check.
device_udid() {
  xcrun devicectl device info details --device "$1" 2>/dev/null \
    | awk -F': ' '/• UDID:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }'
}

BUILD_DESTINATION="generic/platform=iOS"
[[ ${#TARGETS[@]} -gt 0 ]] && BUILD_DESTINATION="platform=iOS,id=${TARGETS[0]#*:}"

if [[ "$NO_BUILD" != "1" ]]; then
  echo "▸ Building universal iPhone/iPad app ($APP_LABEL)..."
  set -o pipefail
  xcodebuild -project Mozz.xcodeproj -scheme Mozz -configuration Debug \
    -destination "$BUILD_DESTINATION" \
    -derivedDataPath .build/dd-device \
    -allowProvisioningUpdates \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" \
    build \
    | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify --quiet || cat; }
fi

APP=$(find .build/dd-device/Build/Products -name "Mozz.app" -type d | head -n1)
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "✗ Could not locate the built Mozz.app." >&2
  exit 1
fi

# Confirm the bundle on disk is the variant we were asked for. install-verified.sh
# takes the bundle id from the .app itself, so a stale bundle would be installed
# under ITS identity, not ours — and with --no-build (which skips the compile that
# would have refreshed it) switching branches or toggling MOZZ_WIDGETS would
# silently install, and overwrite, the canonical app. That's the exact collision
# the per-branch identity exists to prevent, so refuse rather than guess.
APP_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if [[ "$APP_BUNDLE" != "$BUNDLE" ]]; then
  echo "✗ The built app is '$APP_BUNDLE', but this run wants '$BUNDLE'." >&2
  echo "  Re-run without --no-build to rebuild for this variant." >&2
  exit 1
fi

BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")"
echo "✓ Build $BUILD_NUM ready ($(du -sh "$APP" | awk '{print $1}'))."

# --- Provisioning pre-flight -------------------------------------------------
# Confirm the embedded profile actually covers every device we're about to
# install on; otherwise the failure surfaces at install time as 0xe8008012,
# which names neither the device nor the profile. Costs milliseconds.
if [[ ${#TARGETS[@]} -gt 0 && -f "$APP/embedded.mobileprovision" ]]; then
  PROFILE_PLIST="$(mktemp -t mozz-profile)"
  if security cms -D -i "$APP/embedded.mobileprovision" > "$PROFILE_PLIST" 2>/dev/null; then
    PROVISIONED="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" 2>/dev/null || true)"
    # An empty list means a distribution profile (no device list) — not our case.
    if [[ -n "$PROVISIONED" ]]; then
      for entry in "${TARGETS[@]}"; do
        udid="$(device_udid "${entry#*:}")"
        [[ -z "$udid" ]] && continue   # device asleep/offline; let install report it
        if ! grep -q "$udid" <<< "$PROVISIONED"; then
          echo "✗ The provisioning profile doesn't include ${entry%%:*} ($udid)." >&2
          echo "  Installing would fail with 0xe8008012 ('profile cannot be installed')." >&2
          echo "  Usually a stale cached profile. Try, in order:" >&2
          echo "    1. Make sure the device is connected and unlocked, then re-run." >&2
          echo "    2. rm -rf ~/Library/Developer/Xcode/UserData/Provisioning\\ Profiles" >&2
          echo "    3. Confirm the device is registered on the developer portal." >&2
          rm -f "$PROFILE_PLIST"
          exit 1
        fi
      done
    fi
  fi
  rm -f "$PROFILE_PLIST"
fi

[[ "$BUILD_ONLY" == "1" ]] && exit 0

STATUS=0
for entry in "${TARGETS[@]}"; do
  echo "▸ Installing build $BUILD_NUM on ${entry%%:*} (verified)…"
  # --force: we just built fresh code, so always reinstall rather than skip on a
  # matching build number (it can't tell changed-but-uncommitted code apart).
  tools/install-verified.sh "${entry#*:}" "$APP" --force || STATUS=1
done

if [[ "$STATUS" == "0" ]]; then
  echo "✓ Deployed '$APP_LABEL' ($BUNDLE)"
fi
exit "$STATUS"
