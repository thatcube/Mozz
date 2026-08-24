#!/usr/bin/env bash
# Capture App Store screenshots from the real app.
#
# Screenshots can't be assembled afterwards: Mozz derives the Now Playing
# backdrop from the artwork's own colours, so the art has to be in place while
# the shot is taken. This boots a simulator, points the app at a fixture library
# (real names, real covers, real audio — no server, no login), drives the UI, and
# pulls the PNGs out of the result bundle.
#
#   tools/screenshots.sh [fixture-dir] [output-dir]
#
# The fixture defaults to ScreenshotAssets/ in the repo root, which is
# gitignored: the audio and artwork are large binaries that don't belong in git.
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="${1:-$PWD/ScreenshotAssets}"
# The app resolves this at launch, and the simulator has its own working
# directory, so a relative path would silently miss.
FIXTURE="$(cd "$FIXTURE" 2>/dev/null && pwd || echo "$FIXTURE")"
OUT="${2:-$PWD/build/screenshots}"
DEVICE="${MOZZ_SHOT_DEVICE:-iPhone 17 Pro Max}"
SCHEME="Mozz"

# SwiftPM refuses to resolve when the host injects safe.bareRepository=explicit.
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"

if [[ ! -f "$FIXTURE/manifest.json" ]]; then
  echo "✗ No fixture at $FIXTURE (expected manifest.json)." >&2
  echo "  Build one with tools/make-screenshot-fixture.py first." >&2
  exit 1
fi

echo "▸ Fixture: $FIXTURE"
echo "▸ Device:  $DEVICE"

# A simulator that is already booted is reused; simctl treats a redundant boot
# as an error, so it is tolerated rather than guarded with a race-prone check.
UDID="$(xcrun simctl list devices available -j \
  | python3 -c "
import json,sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == name:
            print(d['udid']); raise SystemExit
raise SystemExit('no simulator named ' + name)
" "$DEVICE")"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1 || true

# Pin the appearance and the status bar. The simulator otherwise inherits
# whatever it was last left in, which is how one run comes out dark and the next
# light; and a shipped screenshot should not advertise a half-empty battery.
xcrun simctl ui "$UDID" appearance "${MOZZ_SHOT_APPEARANCE:-dark}" > /dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override \
  --time "9:41" \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState discharging --batteryLevel 100 > /dev/null 2>&1 || true

# How the app finds its fixture. xcodebuild's TEST_RUNNER_ forwarding does not
# reliably reach the app under test, so the value is set on the simulator itself:
# launchctl setenv applies to every process the device spawns afterwards.
xcrun simctl spawn "$UDID" launchctl setenv MOZZ_SCREENSHOT_LIBRARY "$FIXTURE"
trap 'xcrun simctl spawn "$UDID" launchctl unsetenv MOZZ_SCREENSHOT_LIBRARY >/dev/null 2>&1 || true' EXIT

RESULT="$PWD/build/screenshots.xcresult"
DERIVED="$PWD/build/screenshots-dd"
rm -rf "$RESULT" "$OUT"
mkdir -p "$(dirname "$RESULT")" "$OUT"

# Build and install first, so the fixture can be copied *into* the app's
# container. The app is sandboxed and cannot read the fixture from anywhere on
# the host, however visible that path is to the simulator itself.
echo "▸ Building for testing..."
xcodebuild build-for-testing \
  -project Mozz.xcodeproj \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  > build/screenshots-build.log 2>&1 || {
    echo "✗ Build failed. See build/screenshots-build.log" >&2
    tail -20 build/screenshots-build.log >&2
    exit 1
  }

APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name 'Mozz.app' -print -quit)"
[[ -n "$APP" ]] || { echo "✗ Built app not found under $DERIVED" >&2; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

echo "▸ Installing $BUNDLE_ID..."
# Uninstall first. `simctl install` keeps the existing data container, which
# means the seeded database, the artwork cache and — the one that actually bit —
# the lyrics negative cache all survive between runs. A screenshot run has to
# start from a clean app or it shoots whatever the last run happened to leave.
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" > /dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DEST="$CONTAINER/Documents/ScreenshotFixture"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$FIXTURE" "$DEST"
echo "▸ Fixture staged in the app container"

echo "▸ Running the capture test..."
set +e
xcodebuild test-without-building \
  -project Mozz.xcodeproj \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" \
  -only-testing:MozzUITests/ScreenshotTests \
  CODE_SIGNING_ALLOWED=NO \
  > build/screenshots.log 2>&1
STATUS=$?
set -e

# Extract regardless of status: a partial run still produces usable shots, and
# the test deliberately fails at the end when a step was unreachable.
echo "▸ Extracting attachments..."
xcrun xcresulttool export attachments \
  --path "$RESULT" --output-path "$OUT" > /dev/null 2>&1 || true

# Attachments land under generated names; the manifest maps them back to the
# names the test gave each screenshot.
python3 - "$OUT" <<'PY'
import json, os, re, shutil, sys

out = sys.argv[1]
manifest = os.path.join(out, "manifest.json")
if not os.path.exists(manifest):
    raise SystemExit(0)

with open(manifest) as fh:
    data = json.load(fh)

renamed = 0
for entry in data if isinstance(data, list) else [data]:
    for att in entry.get("attachments", []):
        src = os.path.join(out, att.get("exportedFileName", ""))
        want = att.get("suggestedHumanReadableName") or ""
        # XCTest attaches its own UI-hierarchy and debug dumps on every query;
        # only the shots and dumps this test named explicitly are wanted.
        if not re.match(r"^\d\d-", want) or not os.path.exists(src):
            continue
        # XCTest appends its own "_<index>_<UUID>" to every attachment name.
        # Strip it so the output is "01-home.png" — something you can hand to
        # App Store Connect without renaming five files by hand.
        want = re.sub(r"_\d+_[0-9A-Fa-f-]{36}", "", want)
        if not os.path.splitext(want)[1]:
            want += ".txt" if want.startswith("9") else ".png"
        dest = os.path.join(out, want)
        if src != dest:
            shutil.move(src, dest)
        renamed += 1

# Drop everything that wasn't one of ours, so the output directory is exactly
# the screenshot set and its diagnostic dumps.
for name in os.listdir(out):
    if not re.match(r"^\d\d-.*\.(png|txt)$", name):
        path = os.path.join(out, name)
        os.remove(path) if os.path.isfile(path) else shutil.rmtree(path, ignore_errors=True)
print(f"  named {renamed} screenshots")
PY

COUNT=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
if [[ "$COUNT" -eq 0 ]]; then
  echo "✗ No screenshots produced. See build/screenshots.log" >&2
  exit 1
fi
echo "✓ $COUNT screenshots in $OUT"
[[ $STATUS -ne 0 ]] && echo "⚠️  Some steps were unreachable — see build/screenshots.log"
exit 0
