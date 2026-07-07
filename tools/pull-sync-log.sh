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

xcrun devicectl device copy from \
  --device "$DEVICE" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source "Documents/sync-diagnostics.log" \
  --destination "$DEST" >/dev/null 2>&1 || {
    echo "No sync-diagnostics.log yet (run a sync first), or device unavailable." >&2
    exit 1
  }

LOG="$DEST/sync-diagnostics.log"
if [[ "${1:-}" == "--tail" && -n "${2:-}" ]]; then
  tail -n "$2" "$LOG"
else
  cat "$LOG"
fi
