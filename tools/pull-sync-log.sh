#!/usr/bin/env bash
# Pull the Mozz sync-diagnostics log off a physical device — no user interaction.
#
# Live os_log streaming from a physical device is blocked by Apple on modern iOS,
# so the app appends sync timings to Documents/sync-diagnostics.log and we pull
# that file with devicectl (works because the app is development-signed).
#
#   tools/pull-sync-log.sh            # prints the log to stdout
#   tools/pull-sync-log.sh --tail 40  # last 40 lines
set -euo pipefail

DEVICE="${MOZZ_DEVICE:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"
BUNDLE="${MOZZ_BUNDLE:-com.thatcube.Mozz}"
DEST="$(mktemp -d)"

# Pull the Documents directory (pulling a single nested file path is unreliable
# with devicectl; the directory pull works), then read the log out of it.
xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source "Documents" \
  --destination "$DEST" >/dev/null 2>&1 || {
    echo "Device unavailable, or the app isn't installed." >&2
    exit 1
  }

LOG="$DEST/Documents/sync-diagnostics.log"
[[ -f "$LOG" ]] || LOG="$DEST/sync-diagnostics.log"
if [[ ! -f "$LOG" ]]; then
  echo "No sync-diagnostics.log yet — run a sync first." >&2
  exit 1
fi

if [[ "${1:-}" == "--tail" && -n "${2:-}" ]]; then
  tail -n "$2" "$LOG"
else
  cat "$LOG"
fi
