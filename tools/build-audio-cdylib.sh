#!/usr/bin/env bash
#
# Build the audio engine as a shared library (cdylib) the desktop app loads by
# P/Invoke.
#
# The C# desktop app is only a thin shell over the Rust engine in audio/: the
# device, the decoders and the whole DSP chain live in Rust and are reached
# through the C ABI in audio/ffi. .NET binds that ABI with DllImport, which
# needs the *shared* library (libmozz_audio_ffi.dylib / .so / .dll) rather than
# the static one the Swift package links. Without this the app builds and runs
# but the first Play throws DllNotFoundException, because there is nothing to
# load.
#
#   tools/build-audio-cdylib.sh            host architecture, release
#   tools/build-audio-cdylib.sh --debug    unoptimised, for a faster inner loop
#
# It prints the absolute path of the library it produced on the last line, so a
# caller (the .csproj target, or build-macos-app.sh) can copy it next to the
# app without hard-coding the target triple.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO="$ROOT/audio"

# cargo lives in ~/.cargo/bin, which is not on the PATH a `dotnet build` runs
# with. Add it here so the MSBuild target does not have to.
export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "✗ cargo is not installed. Install Rust from https://rustup.rs" >&2
  exit 1
fi

PROFILE="release"
PROFILE_FLAG=(--release)
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE="release"; PROFILE_FLAG=(--release) ;;
    --debug) PROFILE="debug"; PROFILE_FLAG=() ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The cdylib's file name is the platform's, not cargo's: libmozz_audio_ffi.dylib
# on macOS, .so on Linux, mozz_audio_ffi.dll on Windows. The DllImport name in
# C# is just "mozz_audio_ffi"; .NET adds the prefix and suffix per platform.
case "$(uname -s)" in
  Darwin) LIB_NAME="libmozz_audio_ffi.dylib" ;;
  Linux)  LIB_NAME="libmozz_audio_ffi.so" ;;
  MINGW*|MSYS*|CYGWIN*) LIB_NAME="mozz_audio_ffi.dll" ;;
  *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

(cd "$AUDIO" && cargo build -p mozz_audio_ffi "${PROFILE_FLAG[@]+"${PROFILE_FLAG[@]}"}") 1>&2

LIB="$AUDIO/target/$PROFILE/$LIB_NAME"
if [ ! -f "$LIB" ]; then
  echo "✗ $LIB was not produced." >&2
  exit 1
fi

echo "$LIB"
