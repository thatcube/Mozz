#!/usr/bin/env bash
#
# install-verified.sh — reliable CoreDevice install for iPhone / iPad.
#
# WHY THIS EXISTS
# On wireless CoreDevice tunnels (any device not on trusted USB — often the
# iPad), `xcrun devicectl device install` frequently COMPLETES the install but
# then hangs on a post-install tunnel handshake and exits with a "timeout" /
# "Tunnel closed" / "Connection invalidated" error. Trusting that exit code
# makes a successful install look failed, and "retrying" reinstalls something
# already on the device.
#
# So this script never trusts the install command's exit code. Success is
# defined ONLY as "the device now reports the expected CFBundleShortVersionString
# + CFBundleVersion", queried directly. It also:
#   * skips the install entirely if the device already has the target build,
#   * probes the tunnel cheaply and resets degraded CoreDevice daemons,
#   * uses a generous timeout, and
#   * verifies-then-retries a few times instead of blind looping.
#
# USAGE
#   tools/install-verified.sh <core-device-udid> <path-to.app> [--no-launch] [--force]
#
# ENV
#   MOZZ_INSTALL_TIMEOUT    per-attempt install timeout seconds (default 90)
#   MOZZ_INSTALL_ATTEMPTS   max install attempts               (default 3)
#
# Ported from the Plozz deploy tooling, which solved these same failures.
set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <core-device-udid> <path-to.app> [--no-launch] [--force]" >&2
  exit 2
fi

DEVICE="$1"; APP="$2"; shift 2
LAUNCH=1; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    --force)     FORCE=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

TIMEOUT="${MOZZ_INSTALL_TIMEOUT:-90}"
ATTEMPTS="${MOZZ_INSTALL_ATTEMPTS:-3}"

if [[ ! -d "$APP" ]]; then echo "✗ no .app at: $APP" >&2; exit 1; fi
plist="$APP/Info.plist"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
WANT_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
WANT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
LABEL="${BUNDLE##*.} $WANT_VER ($WANT_BUILD)"

# "version build" the device currently reports for BUNDLE, or empty if absent.
# This is the ONE heavy call — slow over a wireless tunnel — so make it rarely.
installed_ver_build() {
  xcrun devicectl device info apps --device "$DEVICE" 2>/dev/null \
    | awk -v b="$BUNDLE" '{for(i=1;i<=NF;i++) if($i==b){print $(i+1), $(i+2); exit}}'
}

matches() { [[ "$1" == "$WANT_VER" && "$2" == "$WANT_BUILD" ]]; }

# Restart the Mac-side CoreDevice daemons. THE key recovery: when these get into
# a degraded state (e.g. after killed/abandoned devicectl processes) a single
# wireless query balloons from ~2-8s to ~90s and installs hang. Killing the two
# on-demand XPC services (launchd respawns them fresh) restores normal speed.
# Match the exact service binaries so unrelated processes are never touched.
reset_coredevice_daemons() {
  echo "  · resetting CoreDevice daemons to recover a degraded tunnel…"
  local pids
  pids="$(pgrep -f 'CoreDeviceService.xpc/Contents/MacOS/CoreDeviceService' 2>/dev/null
          pgrep -f 'remotepairingd.xpc/Contents/MacOS/remotepairingd' 2>/dev/null)"
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  sleep 4
}

echo "▸ Target: $LABEL  →  device $DEVICE"

# Ensure mode only: skip if the device already has this exact version+build.
if [[ "$FORCE" != "1" ]]; then
  read -r cur_v cur_b < <(installed_ver_build || true)
  if matches "${cur_v:-}" "${cur_b:-}"; then
    echo "✓ Already installed ($cur_v/$cur_b) — skipping install."
    SKIP_INSTALL=1
  fi
fi

if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
  # Cheap liveness probe before committing to a long install. A degraded tunnel
  # is the usual reason an install sits for minutes; 15s here replaces up to a
  # full attempt of waiting and costs nothing when the tunnel is healthy.
  if ! xcrun devicectl device info details --device "$DEVICE" --timeout 15 >/dev/null 2>&1; then
    echo "  · device did not answer a 15s probe; tunnel looks degraded"
    reset_coredevice_daemons
  fi

  ok=0
  for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "▸ Install attempt $attempt/$ATTEMPTS (timeout ${TIMEOUT}s)…"
    # A CLEAN exit is the strong success signal, so a clean install makes ZERO
    # extra queries. Only if the command ERRORS do we spend a verify query: on
    # wireless the install often completed and only the final handshake dropped.
    # Heartbeat while it runs — devicectl prints nothing until it finishes, and
    # a silent multi-minute wait is indistinguishable from a hang.
    xcrun devicectl device install app --device "$DEVICE" --timeout "$TIMEOUT" "$APP" \
      >/dev/null 2>&1 &
    install_pid=$!
    waited=0
    while kill -0 "$install_pid" 2>/dev/null; do
      sleep 5
      waited=$((waited + 5))
      if (( waited % 20 == 0 )); then
        echo "  · still installing… ${waited}s of ${TIMEOUT}s"
      fi
    done
    if wait "$install_pid"; then
      echo "✓ Install completed cleanly."
      ok=1; break
    fi
    echo "  · install command errored; verifying by query (slow on wireless)…"
    read -r cur_v cur_b < <(installed_ver_build || true)
    if matches "${cur_v:-}" "${cur_b:-}"; then
      echo "✓ Errored, but device reports target present ($cur_v/$cur_b) — install landed."
      ok=1; break
    fi
    echo "  · attempt $attempt not confirmed (device: ${cur_v:-none}/${cur_b:-none}); retrying…"
    # After the first failure, reset the daemons once — the usual cause of a
    # failed/pathologically-slow wireless install is a degraded daemon.
    if [[ "$attempt" == "1" ]]; then reset_coredevice_daemons; else sleep 3; fi
  done
  if [[ "$ok" != "1" ]]; then
    echo "✗ Could not verify $LABEL on $DEVICE after $ATTEMPTS attempts." >&2
    exit 1
  fi
fi

# Launch — best-effort and SILENT on failure. Install is the only thing that
# matters; a launch can fail for benign reasons (e.g. the device is locked).
if [[ "$LAUNCH" == "1" ]]; then
  if xcrun devicectl device process launch --device "$DEVICE" --timeout 60 "$BUNDLE" >/dev/null 2>&1; then
    echo "✓ Launched $BUNDLE."
  fi
fi
