#!/usr/bin/env bash
#
# Drives the cross-compiled libMozzFFI.so on a booted Android emulator, over adb.
#
# Why this is a file and not inline in the workflow's `script:` —
# reactivecircus/android-emulator-runner executes an inline `script` one line at
# a time, each in its own `sh -c`. Shell variables and `set` options therefore do
# not survive from one line to the next: an inline `DEV=/data/local/tmp/mozz` is
# already gone by the line that uses "$DEV", which then expands empty. Invoking a
# single self-contained file gives us one shell with real variables, errexit and
# pipefail — the environment the steps below actually assume.
set -euo pipefail

# The action's per-line `sh -c` also means we can't rely on the caller's CWD, so
# anchor to the checkout explicitly before touching any repo-relative path.
cd "${GITHUB_WORKSPACE:-.}"

DEV=/data/local/tmp/mozz
TRACK_COUNT="${TRACK_COUNT:-100000}"

adb wait-for-device
adb shell "rm -rf $DEV && mkdir -p $DEV"

# Push the whole payload in one shot: libMozzFFI.so, the Swift runtime .so set it
# DT_NEEDEDs at load time, libc++_shared.so, and the on-device harness binary.
adb push payload/. "$DEV/"
adb push spec/continuity/queue-hash-fixtures.json "$DEV/queue-hash-fixtures.json"
adb shell "chmod 755 $DEV/harness"

echo "running harness with ${TRACK_COUNT} tracks"
# adb shell does not forward the remote process's exit status, so smuggle it out
# in a sentinel line and fail unless the harness returned 0. LD_LIBRARY_PATH points
# at the payload dir so Bionic's loader finds the Swift runtime .so beside the app.
adb shell "cd $DEV && LD_LIBRARY_PATH=$DEV ./harness ./libMozzFFI.so ${TRACK_COUNT} $DEV/mozz-spike.sqlite $DEV/queue-hash-fixtures.json; echo __RC__=\$?" | tee emu-out.txt
grep -q "__RC__=0" emu-out.txt
