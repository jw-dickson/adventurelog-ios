#!/usr/bin/env bash
# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
#
# Simulator helpers that do not hard-code a device name (Xcode versions ship different iPhones).
#
#   scripts/simulator.sh udid          # UDID of the newest available iPhone simulator (boots nothing)
#   scripts/simulator.sh destination   # xcodebuild -destination string for it
#   scripts/simulator.sh boot          # boot it and open Simulator.app
#   scripts/simulator.sh run           # build, install and launch the app on it
#   scripts/simulator.sh drive <gpx>   # replay a recorded drive (Stage 3)
set -euo pipefail
cd "$(dirname "$0")/.."

udid() {
  if [[ -n "${AL_SIMULATOR_UDID:-}" ]]; then echo "$AL_SIMULATOR_UDID"; return; fi
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devices.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in items:
        if not d["name"].startswith("iPhone") or "SE" in d["name"]:
            continue
        key = (version, d["name"])
        if best is None or key > best[0]:
            best = (key, d["udid"])
if best is None:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode → Settings → Components.")
print(best[1])
'
}

case "${1:-}" in
  udid) udid ;;
  destination) echo "platform=iOS Simulator,id=$(udid)" ;;
  boot)
    id=$(udid)
    xcrun simctl boot "$id" 2>/dev/null || true
    # The window is a convenience; headless hosts (CI, or a Mac with no GUI Simulator.app) boot fine without it.
    open -a Simulator --args -CurrentDeviceUDID "$id" 2>/dev/null || true
    xcrun simctl bootstatus "$id" -b >/dev/null
    echo "$id"
    ;;
  run)
    id=$("$0" boot)
    xcodebuild -project AdventureLog.xcodeproj -scheme AdventureLog -configuration Debug \
      -destination "platform=iOS Simulator,id=$id" -derivedDataPath build/DerivedData \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO build -quiet
    app=build/DerivedData/Build/Products/Debug-iphonesimulator/AdventureLog.app
    xcrun simctl install "$id" "$app"
    bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
    xcrun simctl launch "$id" "$bundle" "${@:2}"
    ;;
  drive)
    gpx="${2:?usage: simulator.sh drive <file.gpx>}"
    python3 - "$gpx" "$(udid)" <<'PY'
import subprocess, sys, xml.etree.ElementTree as ET
gpx, udid = sys.argv[1], sys.argv[2]
ns = {"g": "http://www.topografix.com/GPX/1/1"}
points = [f'{p.get("lat")},{p.get("lon")}' for p in ET.parse(gpx).getroot().iterfind(".//g:trkpt", ns)]
if not points:
    sys.exit("no <trkpt> points in " + gpx)
subprocess.run(["xcrun", "simctl", "location", udid, "start", "--speed=25", *points], check=True)
PY
    ;;
  *) sed -n '4,11p' "$0"; exit 1 ;;
esac
