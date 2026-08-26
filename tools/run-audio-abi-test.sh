#!/usr/bin/env bash
#
# Compile a C program against the generated header, link the real staticlib, and
# run it.
#
# This is the only check that proves the boundary is usable rather than merely
# well-formed. cbindgen will happily emit a header for a crate whose staticlib
# fails to build, and a Rust test will happily pass while exporting a symbol C
# cannot name. Linking is what catches both, and it catches them here rather
# than a long way into an Xcode build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO="$ROOT/audio"
HEADER_DIR="$AUDIO/ffi/include"
SOURCE="$AUDIO/ffi/tests/abi_smoke.c"

export PATH="$HOME/.cargo/bin:$PATH"

echo "▸ Building the staticlib…"
(cd "$AUDIO" && cargo build --release -p mozz_audio_ffi)

LIB="$AUDIO/target/release/libmozz_audio_ffi.a"
if [ ! -f "$LIB" ]; then
  echo "✗ $LIB was not produced." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rust's staticlib does not carry the system frameworks it needs, so the C side
# names them. On macOS that is CoreAudio and friends for cpal; on Linux, ALSA
# and the usual pthread/dl/m set.
case "$(uname -s)" in
  Darwin)
    FRAMEWORKS=(-framework CoreAudio -framework AudioToolbox -framework CoreFoundation -framework AudioUnit)
    EXTRA=()
    ;;
  *)
    FRAMEWORKS=()
    EXTRA=(-lasound -lpthread -ldl -lm)
    ;;
esac

echo "▸ Compiling and linking the smoke test…"
cc -std=c11 -Wall -Wextra -Werror \
  -I "$HEADER_DIR" \
  "$SOURCE" "$LIB" \
  ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} \
  -o "$TMP/abi_smoke"

echo "▸ Running…"
"$TMP/abi_smoke"
