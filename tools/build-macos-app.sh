#!/usr/bin/env bash
#
# Build Mozz Desktop as a real macOS .app bundle.
#
# WHY THIS EXISTS
#
# `dotnet publish` produces a folder with a bare executable in it. On Windows and
# Linux that is genuinely what you ship. On macOS it is not an app: double-clicking
# it opens a Terminal window, it has no icon in the Dock, it cannot be dragged to
# Applications, and Gatekeeper treats it as an unidentified binary rather than
# something with a bundle identifier.
#
# So this assembles the bundle macOS expects, gives it the app icon as an .icns,
# and signs it with whatever codesigning certificate is on the machine, falling
# back to ad-hoc when there is none. A real certificate matters for more than
# tidiness: the Keychain identifies an app by its designated requirement, and an
# ad-hoc one is a hash of the binary, so every rebuild looked like a brand new
# program and re-prompted for the Keychain password. Distributing to other
# people additionally needs notarisation, which is a separate job with its own
# credentials — see fastlane for how the iOS side does it.
#
#   tools/build-macos-app.sh              → build/Mozz.app
#   tools/build-macos-app.sh --run        → build it and launch it
#   tools/build-macos-app.sh --library X  → launch against a specific library file
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

RUN=0
LIBRARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN=1; shift ;;
    --library) LIBRARY="$2"; RUN=1; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# SwiftPM refuses to resolve in this worktree without it; see AGENTS.local.md.
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
export PATH="$DOTNET_ROOT:$PATH"
# ~/.nuget is root-owned on this machine.
export NUGET_PACKAGES="${NUGET_PACKAGES:-$HOME/Development/.nuget-packages}"
eval "$(tools/version-info.py --format shell)"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) RID="osx-arm64" ;;
  x86_64) RID="osx-x64" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

APP="build/Mozz.app"
STAGE="build/publish-$RID"

echo "▸ Building the Swift core…"
swift build -c release --product MozzFFI

echo "▸ Publishing the app ($RID, self-contained)…"
rm -rf "$STAGE"
dotnet publish clients/desktop/Mozz.Desktop.csproj \
  -c Release -r "$RID" --self-contained true \
  -p:UseAppHost=true \
  -p:MozzMarketingVersion="$MOZZ_RESOLVED_MARKETING_VERSION" \
  -p:MozzBuildNumber="$MOZZ_RESOLVED_BUILD_NUMBER" \
  -p:MozzDisplayVersion="$MOZZ_RESOLVED_DISPLAY_VERSION" \
  -p:MozzAssemblyVersion="$MOZZ_RESOLVED_ASSEMBLY_VERSION" \
  -p:MozzFileVersion="$MOZZ_RESOLVED_FILE_VERSION" \
  -o "$STAGE" \
  --nologo -v quiet
cp .build/release/libMozzFFI.dylib "$STAGE/"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Everything published goes in MacOS/ so the executable finds its runtime and
# libMozzFFI.dylib beside it, which is where dlopen looks first.
cp -R "$STAGE/." "$APP/Contents/MacOS/"

# The icon. iconutil wants a specific set of sizes and @2x names; anything
# missing shows as a generic document in some contexts and not others.
ICONSET="build/Mozz.iconset"
SOURCE_ICON="App/Mozz/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
if [ -f "$SOURCE_ICON" ]; then
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SOURCE_ICON" \
      --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Mozz.icns"
  rm -rf "$ICONSET"
else
  echo "  (no source icon at $SOURCE_ICON — bundle will use the generic one)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mozz</string>
  <key>CFBundleDisplayName</key><string>Mozz</string>
  <key>CFBundleIdentifier</key><string>com.thatcube.Mozz.desktop</string>
  <key>CFBundleExecutable</key><string>Mozz.Desktop</string>
  <key>CFBundleIconFile</key><string>Mozz</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$MOZZ_RESOLVED_MARKETING_VERSION</string>
  <key>CFBundleVersion</key><string>$MOZZ_RESOLVED_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Mozz plays from a server the user runs, which is almost always on the
       local network. Since macOS 15 an app must declare why it needs local
       network access before the system will even offer the permission prompt;
       without this key the request is refused silently and every LAN
       connection fails as EHOSTUNREACH, which surfaces as "No route to host"
       from .NET while curl on the same machine succeeds.

       That is exactly what happened when this bundle was first signed with a
       real certificate: the signing identity changed, macOS treated it as a
       new app, the previously granted permission no longer applied, and album
       art and profile pictures stopped loading with nothing in the UI to say
       why. Streaming kept working only because decoding happens in a separate
       FFmpeg process with its own grant. -->
  <key>NSLocalNetworkUsageDescription</key><string>Mozz connects to your media server to stream music and download album art. Your server is usually on your local network.</string>
  <!-- This script is the local developer bundler. Marking its bundles lets the
       credential store avoid legacy Keychain ACL prompts that only happen
       because this binary is rebuilt constantly. Release/notarised bundles are
       not produced here and therefore keep using the Keychain. -->
  <key>MozzLocalDevelopmentBuild</key><true/>
  <!-- Without this the process is a background agent: no Dock icon, no menu
       bar, and the window cannot be brought to the front. -->
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Free forever, open source.</string>
</dict>
</plist>
PLIST

# Signing.
#
# This used to sign ad-hoc, and that is why the Keychain asked for a password on
# every single launch. A Keychain ACL remembers the app it trusts by that app's
# *designated requirement*, and an ad-hoc signature's requirement is
# `cdhash H"..."` — a hash of the binary itself. Every rebuild produces a
# different binary and therefore a different requirement, so macOS correctly
# concluded it had never seen this program before and asked again. Clicking
# "Always Allow" pinned exactly one build and was void the next time the app was
# compiled.
#
# Signing with a real certificate instead gives a requirement written in terms
# of the bundle identifier and the signing certificate, both of which survive a
# rebuild — so the ACL keeps matching and the prompt happens once.
#
# The identity is discovered rather than hard-coded, and MOZZ_CODESIGN_IDENTITY
# overrides it. Ad-hoc remains the fallback, because a bundle containing a
# self-contained .NET runtime is refused outright on Apple silicon unless every
# Mach-O carries at least an ad-hoc signature — which is also why the nested
# binaries are signed before the bundle around them.
IDENTITY="${MOZZ_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
  echo "▸ Signing as ${IDENTITY}…"
  SIGN=(--force --sign "$IDENTITY" --timestamp=none)
else
  echo "▸ Signing (ad-hoc — no certificate found, so the Keychain will ask again after every rebuild)…"
  SIGN=(--force --sign - --timestamp=none)
fi

find "$APP/Contents/MacOS" -type f \( -name "*.dylib" -o -name "*.so" \) \
  -exec codesign "${SIGN[@]}" {} \; 2>/dev/null || true
codesign "${SIGN[@]}" --deep "$APP" 2>/dev/null \
  || echo "  (codesign reported an issue; the app may still run)"

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ $APP ($SIZE) — version $MOZZ_RESOLVED_DISPLAY_VERSION"

if [ "$RUN" = "1" ]; then
  # Launch from /Applications, never from the build directory.
  #
  # macOS only grants local network access to an app running from a normal
  # install location. Run the same signed bundle out of a worktree's build/
  # folder and every connection to a LAN server fails with EHOSTUNREACH, while
  # curl, nc and the child ffmpeg process all reach it fine - so music plays and
  # album art silently does not, and the app never appears in the Local Network
  # settings list to be granted. That cost a full evening to find. Copying first
  # takes a second and removes the whole class of problem.
  INSTALLED="/Applications/$(basename "$APP")"
  echo "▸ Installing to $INSTALLED…"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"

  echo "▸ Launching…"
  if [ -n "$LIBRARY" ]; then
    MOZZ_LIBRARY="$LIBRARY" open -n "$INSTALLED"
  else
    open -n "$INSTALLED"
  fi
fi
