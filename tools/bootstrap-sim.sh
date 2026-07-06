#!/usr/bin/env bash
# Create + boot an iOS Simulator device for Mozz ("Mozz iPhone").
# Idempotent: reuses the device if it already exists.
set -euo pipefail

DEVICE_NAME="${MOZZ_SIM_NAME:-Mozz iPhone}"

# Pick the newest installed iOS runtime and an iPhone device type it actually
# supports (older device types are rejected by newer runtimes).
read -r RUNTIME DEVTYPE < <(xcrun simctl list runtimes --json | python3 -c '
import json, re, sys
rs = [r for r in json.load(sys.stdin)["runtimes"]
      if r.get("isAvailable") and "iOS" in r["name"]]
if not rs:
    sys.exit("No iOS runtime installed")
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
rt = rs[-1]
phones = [d for d in rt.get("supportedDeviceTypes", []) if "iPhone" in d["name"]]
def rank(d):
    m = re.search(r"iPhone (\d+)", d["name"])
    num = int(m.group(1)) if m else 0
    pro = 1 if "Pro" in d["name"] else 0
    mini = -1 if ("mini" in d["name"] or "SE" in d["name"]) else 0
    return (num, pro, mini)
phones.sort(key=rank)
print(rt["identifier"], phones[-1]["identifier"])
')

EXISTING=$(xcrun simctl list devices --json \
  | python3 -c "import json,sys; 
devs=json.load(sys.stdin)['devices']; 
u=[d['udid'] for rt,ds in devs.items() for d in ds if d['name']=='$DEVICE_NAME']; 
print(u[0] if u else '')")

if [[ -z "$EXISTING" ]]; then
  echo "▸ Creating simulator '$DEVICE_NAME' ($DEVTYPE on $RUNTIME)…" >&2
  EXISTING=$(xcrun simctl create "$DEVICE_NAME" "$DEVTYPE" "$RUNTIME")
fi

echo "▸ Booting $DEVICE_NAME ($EXISTING)…" >&2
xcrun simctl boot "$EXISTING" 2>/dev/null || true
printf '%s\n' "$EXISTING"
