#!/usr/bin/env bash
#
# Build the audio engine as a static library the Swift package can link.
#
# SwiftPM cannot run cargo, so this runs first and leaves a `.a` where
# Package.swift expects it. That is a real cost - `swift build` now has a
# prerequisite - and it is the honest consequence of the core containing a Rust
# engine rather than a pretend one behind a flag.
#
#   tools/build-audio-staticlib.sh              host architecture, debug
#   tools/build-audio-staticlib.sh --release    optimised
#   tools/build-audio-staticlib.sh --universal  arm64 + x86_64 lipo'd together
#
# --universal is what a shipped Mac build needs; the default is what a laptop
# needs, and taking twice as long by default would be paid on every build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO="$ROOT/audio"
OUT="$AUDIO/target/swift"
LIB_NAME="libmozz_audio_ffi.a"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "✗ cargo is not installed. Install Rust from https://rustup.rs" >&2
  exit 1
fi

PROFILE="debug"
PROFILE_FLAG=()
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE="release"; PROFILE_FLAG=(--release) ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"

build_for() {
  local target="$1"
  # Adding the target is idempotent and cheap, and failing here with a clear
  # message beats a linker error about a missing architecture later.
  rustup target add "$target" >/dev/null 2>&1 || true
  (cd "$AUDIO" && cargo build -p mozz_audio_ffi "${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"}" --target "$target")
  echo "$AUDIO/target/$target/$PROFILE/$LIB_NAME"
}

if [ "$UNIVERSAL" = "1" ]; then
  echo "▸ Building arm64 and x86_64…"
  ARM="$(build_for aarch64-apple-darwin | tail -1)"
  INTEL="$(build_for x86_64-apple-darwin | tail -1)"
  lipo -create "$ARM" "$INTEL" -output "$OUT/$LIB_NAME"
else
  echo "▸ Building for this machine…"
  (cd "$AUDIO" && cargo build -p mozz_audio_ffi "${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"}")
  cp "$AUDIO/target/$PROFILE/$LIB_NAME" "$OUT/$LIB_NAME"
fi

# The header travels with the library, so a stale header and a fresh library
# cannot end up in the same place.
"$ROOT/tools/generate-audio-header.sh" >/dev/null
mkdir -p "$OUT/include"
cp "$AUDIO/ffi/include/mozz_audio.h" "$OUT/include/"
cat > "$OUT/include/module.modulemap" <<'MODMAP'
// Lets Swift import the C ABI as a module rather than a bridging header,
// because a SwiftPM package has no bridging header to put it in.
module MozzAudioFFI {
    header "mozz_audio.h"
    export *
}
MODMAP

SIZE="$(du -h "$OUT/$LIB_NAME" | cut -f1)"
echo "✓ $OUT/$LIB_NAME ($SIZE, $PROFILE)"
if [ "$UNIVERSAL" = "1" ]; then
  lipo -info "$OUT/$LIB_NAME" | sed 's/^/  /'
fi
