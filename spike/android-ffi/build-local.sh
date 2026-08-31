#!/usr/bin/env bash
#
# Cross-compile libMozzFFI.so for Android on this Mac, build the harness with
# the NDK, and (optionally) run the whole gate battery on a plugged-in phone.
#
# The macOS counterpart to `.github/workflows/android-ffi-spike.yml`. The
# workflow is still the source of truth for CI numbers; this exists so the loop
# is seconds instead of a push-and-wait, and so the gates can run on a *real*
# arm64 phone rather than a virtualised x86_64 emulator.
#
#   ./spike/android-ffi/build-local.sh                 # build only
#   ./spike/android-ffi/build-local.sh --run           # build, then run on device
#   ./spike/android-ffi/build-local.sh --run --tracks 20000 \
#       --https-url https://plex.tv                    # smaller catalog, real host
#
# Everything it downloads (the SQLite amalgamation) is cached under .build/.

set -euo pipefail

ARCH="aarch64"                 # the Pixel and every other modern phone
API=28                         # matches the CI triples
TRACKS=20000                   # a local run wants feedback, not the 100k CI figure
RUN_ON_DEVICE=0
HTTPS_URL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --run)        RUN_ON_DEVICE=1; shift ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --tracks)     TRACKS="$2"; shift 2 ;;
        --https-url)  HTTPS_URL="$2"; shift 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$ARCH" in
    aarch64) SDK_TRIPLE="aarch64-unknown-linux-android${API}"; CLANG_TRIPLE="aarch64-linux-android${API}"; NDK_LIB_TRIPLE="aarch64-linux-android"; ABI="arm64-v8a" ;;
    x86_64)  SDK_TRIPLE="x86_64-unknown-linux-android${API}";  CLANG_TRIPLE="x86_64-linux-android${API}";  NDK_LIB_TRIPLE="x86_64-linux-android";  ABI="x86_64" ;;
    *) echo "unsupported arch: $ARCH (want aarch64 or x86_64)" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# The repo is checked out in a way that trips SwiftPM's bare-repository guard.
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
export PATH="$HOME/.swiftly/bin:$PATH"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# --- Toolchain -------------------------------------------------------------

say "Toolchain"
command -v swift >/dev/null || { echo "swift not on PATH (swiftly not installed?)" >&2; exit 1; }
swift --version | head -1

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$(ls -d "$HOME/Library/Android/sdk/ndk/"*/ 2>/dev/null | sort -V | tail -1 || true)"
    ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
fi
[ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ] \
    || { echo "no NDK found. Install one (r27+) or set ANDROID_NDK_HOME." >&2; exit 1; }
export ANDROID_NDK_HOME
echo "NDK: $ANDROID_NDK_HOME"

NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[ -x "$NDK_BIN/clang" ] || { echo "no clang at $NDK_BIN" >&2; exit 1; }

BUNDLE="$(ls -d "$HOME/Library/org.swift.swiftpm/swift-sdks/"*android.artifactbundle 2>/dev/null | head -1 || true)"
if [ -z "$BUNDLE" ]; then
    BUNDLE="$(ls -d "$HOME/.swiftpm/swift-sdks/"*android.artifactbundle 2>/dev/null | head -1 || true)"
fi
[ -n "$BUNDLE" ] || { echo "the Swift Android SDK is not installed — see spike/android-ffi/README.md" >&2; exit 1; }
echo "Swift Android SDK: $BUNDLE"

# The bundle ships without a sysroot; setup-android-sdk.sh links the NDK into it.
# It is idempotent, but it is also slow, so only run it when the sysroot is bare.
if [ ! -e "$BUNDLE/swift-android/ndk-sysroot/usr/include/stdio.h" ]; then
    say "Linking the NDK into the Swift Android SDK (one time)"
    ( cd "$BUNDLE/swift-android" && ./scripts/setup-android-sdk.sh )
fi

STATIC_LIBS="$BUNDLE/swift-android/swift-resources/usr/lib/swift_static-${ARCH}/android"
RUNTIME_LIBS="$BUNDLE/swift-android/swift-resources/usr/lib/swift-${ARCH}/android"
LIBCXX_SHARED="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/${NDK_LIB_TRIPLE}/libc++_shared.so"

# --- SQLite ----------------------------------------------------------------
#
# Android's system SQLite is a private platform library and is frequently built
# without FTS5, which Mozz search cannot live without. Compile the amalgamation
# ourselves and archive it straight into the .so. See ADR-0014.

SQLITE_VERSION="3510000"
SQLITE_ROOT="$REPO_ROOT/.build/android-sqlite-${ARCH}"
if [ ! -f "$SQLITE_ROOT/lib/libsqlite3.a" ]; then
    say "Building SQLite ${SQLITE_VERSION} for ${ARCH} (FTS5 on)"
    mkdir -p "$SQLITE_ROOT/include" "$SQLITE_ROOT/lib"
    if [ ! -d "$SQLITE_ROOT/sqlite-amalgamation-${SQLITE_VERSION}" ]; then
        curl -fSL -o "$SQLITE_ROOT/amalgamation.zip" \
            "https://sqlite.org/2025/sqlite-amalgamation-${SQLITE_VERSION}.zip"
        unzip -q "$SQLITE_ROOT/amalgamation.zip" -d "$SQLITE_ROOT"
    fi
    SRC="$SQLITE_ROOT/sqlite-amalgamation-${SQLITE_VERSION}"
    cp "$SRC/sqlite3.h" "$SRC/sqlite3ext.h" "$SQLITE_ROOT/include/"
    "$NDK_BIN/clang" --target="$CLANG_TRIPLE" -c -O2 -fPIC \
        -DSQLITE_ENABLE_FTS5 \
        -DSQLITE_ENABLE_SNAPSHOT \
        -DSQLITE_ENABLE_PREUPDATE_HOOK \
        -DSQLITE_ENABLE_COLUMN_METADATA \
        -DSQLITE_ENABLE_STAT4 \
        -DSQLITE_ENABLE_RTREE \
        -DSQLITE_ENABLE_JSON1 \
        -DSQLITE_THREADSAFE=1 \
        -DSQLITE_DQS=0 \
        "$SRC/sqlite3.c" -o "$SQLITE_ROOT/sqlite3.o"
    "$NDK_BIN/llvm-ar" rcs "$SQLITE_ROOT/lib/libsqlite3.a" "$SQLITE_ROOT/sqlite3.o"
    # Counted, not `grep -q`: a quiet grep closes the pipe on its first match,
    # llvm-nm takes SIGPIPE, and `pipefail` then reports the *successful* check
    # as a failure. The CI workflow counts for the same reason.
    FTS5_SYMS="$("$NDK_BIN/llvm-nm" "$SQLITE_ROOT/lib/libsqlite3.a" | grep -ci fts5 || true)"
    [ "${FTS5_SYMS:-0}" -gt 0 ] \
        || { echo "the amalgamation built without FTS5 — search would be dead on arrival" >&2; exit 1; }
    echo "libsqlite3.a built, FTS5 present (${FTS5_SYMS} symbols)"
else
    echo "SQLite: cached at $SQLITE_ROOT"
fi

# --- The core --------------------------------------------------------------
#
# The nested `swift_static-<arch>/android` search path is not optional: the SDK
# keeps Foundation's networking archives one directory deeper than the driver
# looks, and without it the link fails with `unable to find library
# -l_CFURLSessionInterface` — a message that names a symbol, not the directory.

# `-soname` is not cosmetic. Without a DT_SONAME, anything that links against
# this .so records the *absolute path it was built at* as its dependency — so the
# JNI shim would ask a phone for /Users/…/libMozzFFI.so and fail to load. With
# it, the dependency is recorded as the bare name and the Android linker finds it
# in the APK's lib/<abi>/ directory like any other library.
say "Cross-compiling libMozzFFI.so for ${ARCH}"
swift build -c release --swift-sdk "$SDK_TRIPLE" --static-swift-stdlib \
    -Xcc -I"$SQLITE_ROOT/include" \
    -Xlinker -L"$SQLITE_ROOT/lib" \
    -Xlinker -L"$STATIC_LIBS" \
    -Xlinker -soname -Xlinker libMozzFFI.so \
    --product MozzFFI

SO_PATH="$(find .build -path "*${SDK_TRIPLE}*" -name libMozzFFI.so | head -1)"
[ -n "$SO_PATH" ] || { echo "built, but libMozzFFI.so was not where it was expected" >&2; exit 1; }
echo "linked $SO_PATH ($(du -h "$SO_PATH" | cut -f1))"

say "Exported ABI"
DEFINED="$("$NDK_BIN/llvm-nm" -D --defined-only "$SO_PATH")"
MISSING=0
for s in mozz_session_open mozz_session_call mozz_session_close mozz_ffi_free_string \
         mozz_ffi_probe mozz_ffi_benchmark mozz_ffi_search mozz_ffi_probe_hpke \
         mozz_ffi_probe_https mozz_ffi_verify_continuity_hashes; do
    if [ "$(printf '%s\n' "$DEFINED" | grep -cE "[[:space:]]${s}\$" || true)" -gt 0 ]; then
        echo "  ok       $s"
    else
        echo "  MISSING  $s"; MISSING=1
    fi
done
[ "$MISSING" -eq 0 ] || { echo "the C ABI is incomplete" >&2; exit 1; }

# --- The harness + the runtime payload -------------------------------------

say "Building the harness and staging the payload"
STAGE="$REPO_ROOT/.build/android-stage-${ARCH}"
rm -rf "$STAGE"; mkdir -p "$STAGE"

"$NDK_BIN/clang" --target="$CLANG_TRIPLE" -O2 \
    "$REPO_ROOT/spike/android-ffi/harness/android_harness.c" \
    -o "$STAGE/android_harness" -ldl -lm

cp "$SO_PATH" "$STAGE/"
# `--static-swift-stdlib` does not make the object standalone on Android: the
# .so still lists the Swift Android runtime and libc++ as DT_NEEDED. Whatever
# ships — this harness today, the APK's jniLibs/<abi>/ tomorrow — carries them.
# Everything except the testing runtime. swift-testing and XCTest ship in the
# SDK's runtime directory, nothing in the shipped graph has them as DT_NEEDED,
# and an APK has no business carrying a test framework.
for so in "$RUNTIME_LIBS"/*.so; do
    case "$(basename "$so")" in
        libXCTest.so|libTesting.so|lib_TestingInterop.so|lib_Testing_Foundation.so) continue ;;
    esac
    cp "$so" "$STAGE/" 2>/dev/null || true
done
cp "$LIBCXX_SHARED" "$STAGE/" 2>/dev/null || true
cp "$REPO_ROOT/spec/continuity/queue-hash-fixtures.json" "$STAGE/"
echo "payload: $(ls -1 "$STAGE"/*.so | wc -l | tr -d ' ') shared objects + harness"
echo "         $STAGE"
echo
echo "This directory is also the manifest for the APK's jniLibs/${ABI}/."

[ "$RUN_ON_DEVICE" -eq 1 ] || { say "Built. Re-run with --run to execute on a device."; exit 0; }

# --- Run on the phone ------------------------------------------------------

say "Running the gates on a device"
command -v adb >/dev/null || { echo "adb not on PATH" >&2; exit 1; }
DEVICE_COUNT="$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
if [ "$DEVICE_COUNT" -eq 0 ]; then
    echo "No device. Plug the phone in, enable USB debugging, accept the prompt," >&2
    echo "and check with: adb devices" >&2
    exit 1
fi

REMOTE=/data/local/tmp/mozz-spike
adb shell "rm -rf $REMOTE && mkdir -p $REMOTE"
adb push --sync "$STAGE/." "$REMOTE" >/dev/null
adb shell "chmod 755 $REMOTE/android_harness"
set +e
adb shell "cd $REMOTE && LD_LIBRARY_PATH=$REMOTE ./android_harness \
    $REMOTE/libMozzFFI.so $TRACKS $REMOTE/mozz-spike.sqlite \
    $REMOTE/queue-hash-fixtures.json ${HTTPS_URL}"
STATUS=$?
set -e
exit $STATUS
