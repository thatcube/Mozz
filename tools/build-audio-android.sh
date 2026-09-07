#!/usr/bin/env bash
#
# Build the shared audio DSP for Android and drop it where Gradle packages it.
#
# Android keeps ExoPlayer — it decodes, it speaks the HLS that Plex transcodes
# need, and it owns the media session the car and the lock screen come from —
# and borrows only the filters. See ADR-0015: the harm being avoided is two
# implementations of the same equaliser that nothing forces to agree, not two
# players.
#
# The NDK ships the only linker that can produce these, so its location is the
# one thing this cannot guess. ANDROID_NDK_HOME overrides the default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO="$ROOT/audio"
JNI_LIBS="$ROOT/clients/android/app/src/main/jniLibs"
PROFILE="${PROFILE:-release}"

NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
    # Newest installed, so a machine with several does not get the oldest.
    NDK="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
    echo "✗ No Android NDK. Install one, or set ANDROID_NDK_HOME." >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin) HOST=darwin-x86_64 ;;
    Linux)  HOST=linux-x86_64 ;;
    *) echo "✗ Unsupported host for the NDK toolchain: $(uname -s)" >&2; exit 1 ;;
esac
TOOLS="$NDK/toolchains/llvm/prebuilt/$HOST/bin"

# 28 is minSdk 28 in app/build.gradle.kts. Linking against a newer platform
# than the app claims to support is how a library ends up calling a symbol that
# is not there on somebody's phone.
API=28

# Rust triple → the ABI directory Gradle packages it from.
ABIS=(
    "aarch64-linux-android:arm64-v8a"
    "x86_64-linux-android:x86_64"
)

built=0
for entry in "${ABIS[@]}"; do
    triple="${entry%%:*}"
    abi="${entry##*:}"

    if ! rustup target list --installed | grep -qx "$triple"; then
        echo "• skipping $abi: rustup target $triple is not installed"
        continue
    fi

    upper="$(echo "$triple" | tr 'a-z-' 'A-Z_')"
    clang="$TOOLS/${triple}${API}-clang"
    if [ ! -x "$clang" ]; then
        echo "• skipping $abi: no $clang" >&2
        continue
    fi

    # 16 KB pages. Android 15 and later run on devices with a 16 KB page size,
    # and the loader refuses a library whose LOAD segments are aligned for 4 KB
    # — which is the linker's default. A Pixel says so out loud in a dialog
    # listing the offending library by name; a user's phone would simply fail
    # to load it and lose the equaliser with no explanation.
    env \
        "CARGO_TARGET_${upper}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384" \
        "CARGO_TARGET_${upper}_LINKER=$clang" \
        "CC_${triple//-/_}=$clang" \
        "AR_${triple//-/_}=$TOOLS/llvm-ar" \
        cargo build \
            --manifest-path "$AUDIO/Cargo.toml" \
            -p mozz_audio_android \
            --target "$triple" \
            $([ "$PROFILE" = release ] && echo --release)

    mkdir -p "$JNI_LIBS/$abi"
    cp "$AUDIO/target/$triple/$PROFILE/libmozz_audio_android.so" "$JNI_LIBS/$abi/"
    echo "✓ $abi $(du -h "$JNI_LIBS/$abi/libmozz_audio_android.so" | cut -f1)"
    built=$((built + 1))
done

if [ "$built" -eq 0 ]; then
    echo "✗ Nothing built. Add a target with: rustup target add aarch64-linux-android" >&2
    exit 1
fi
