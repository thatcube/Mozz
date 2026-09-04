#!/usr/bin/env bash
#
# Build the audio engine as an XCFramework the Swift package can link on every
# Apple platform.
#
# The first version of this produced one `.a` into a single directory and named
# it with `-L`. That works exactly until something other than a Mac tries to
# build: an iOS device needs an arm64-ios slice, the simulator needs its own,
# and a single directory can only hold one of them. SwiftPM cannot even tell
# device from simulator - both are `.iOS` - so per-platform linker flags cannot
# express it either.
#
# An XCFramework can. Xcode picks the right slice per destination, and the
# package links a `binaryTarget` instead of carrying `unsafeFlags` - which
# matters beyond tidiness, because a package using unsafeFlags cannot be
# depended on by anything else.
#
#   tools/build-audio-xcframework.sh            macOS only, fast, for a laptop
#   tools/build-audio-xcframework.sh --all      every Apple platform, for shipping
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO="$ROOT/audio"
OUT="$AUDIO/target/MozzAudioFFI.xcframework"
STAGE="$AUDIO/target/xcstage"
LIB="libmozz_audio_ffi.a"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "✗ cargo is not installed. Install Rust from https://rustup.rs" >&2
  exit 1
fi

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

# The header travels with the library so a stale header and a fresh library
# cannot end up in the same slice.
"$ROOT/tools/generate-audio-header.sh" >/dev/null
HEADERS="$STAGE/include"
rm -rf "$STAGE"
mkdir -p "$HEADERS"
cp "$AUDIO/ffi/include/mozz_audio.h" "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'MODMAP'
module MozzAudioFFI {
    header "mozz_audio.h"
    export *
}
MODMAP

build() {
  local target="$1"
  rustup target add "$target" >/dev/null 2>&1 || true
  (cd "$AUDIO" && cargo build --release -p mozz_audio_ffi --target "$target" >/dev/null)
  echo "$AUDIO/target/$target/release/$LIB"
}

fuse() {
  # One slice per platform, with every architecture that platform can run.
  local name="$1"; shift
  local out="$STAGE/$name/$LIB"
  mkdir -p "$(dirname "$out")"
  lipo -create "$@" -output "$out"
  echo "$out"
}

ARGS=()

echo "▸ macOS…"
MAC_ARM="$(build aarch64-apple-darwin)"
MAC_X86="$(build x86_64-apple-darwin)"
MAC="$(fuse macos "$MAC_ARM" "$MAC_X86")"
ARGS+=(-library "$MAC" -headers "$HEADERS")

if [ "$ALL" = "1" ]; then
  echo "▸ iOS device…"
  IOS="$(build aarch64-apple-ios)"
  IOS_SLICE="$(fuse ios "$IOS")"
  ARGS+=(-library "$IOS_SLICE" -headers "$HEADERS")

  echo "▸ iOS simulator…"
  SIM_ARM="$(build aarch64-apple-ios-sim)"
  SIM_X86="$(build x86_64-apple-ios)"
  SIM="$(fuse ios-simulator "$SIM_ARM" "$SIM_X86")"
  ARGS+=(-library "$SIM" -headers "$HEADERS")
fi

rm -rf "$OUT"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT" >/dev/null

echo "✓ $OUT"
/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$OUT/Info.plist" 2>/dev/null \
  | grep -E "LibraryIdentifier" | sed 's/^/  /' || true
