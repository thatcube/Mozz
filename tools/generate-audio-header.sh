#!/usr/bin/env bash
#
# Regenerate the C header for the audio engine's boundary crate.
#
# The header is generated rather than written, because a hand-written one drifts
# from the Rust silently: a signature changes, the header does not, and the
# mismatch is not a compile error on either side. It is a corrupted argument at
# run time, inside an audio callback, on whichever platform happened to link the
# stale copy. Generating removes the possibility.
#
#   tools/generate-audio-header.sh            regenerate in place
#   tools/generate-audio-header.sh --check    fail if the committed copy is stale
#
# The --check form is what CI runs, so a header committed out of date is a
# build failure rather than something discovered by a user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFI="$ROOT/audio/ffi"
HEADER="$FFI/include/mozz_audio.h"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cbindgen >/dev/null 2>&1; then
  echo "cbindgen is not installed. Install it with:" >&2
  echo "  cargo install cbindgen" >&2
  exit 1
fi

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

(cd "$FFI" && cbindgen --config cbindgen.toml --crate mozz_audio_ffi --output "$TMP/mozz_audio.h" --quiet)

if [ "$CHECK" = "1" ]; then
  if [ ! -f "$HEADER" ]; then
    echo "✗ $HEADER is missing. Run tools/generate-audio-header.sh." >&2
    exit 1
  fi
  if ! diff -u "$HEADER" "$TMP/mozz_audio.h" >/dev/null; then
    echo "✗ The committed C header does not match the Rust it describes." >&2
    echo "  Run tools/generate-audio-header.sh and commit the result." >&2
    diff -u "$HEADER" "$TMP/mozz_audio.h" >&2 || true
    exit 1
  fi
  echo "✓ The C header matches the Rust."
  exit 0
fi

mkdir -p "$(dirname "$HEADER")"
cp "$TMP/mozz_audio.h" "$HEADER"
echo "✓ $HEADER"
