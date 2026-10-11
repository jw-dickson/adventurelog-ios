#!/usr/bin/env bash
# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
#
# Drives the booted Simulator through a short, made-up version of day 4 of the synthetic trip
# (Tasmania), so tracking and the Log can be checked without leaving the desk:
#
#   scripts/replay-drive.sh            # about 30 minutes: three stops, two drives
#   DWELL=360 SPEED=400 scripts/replay-drive.sh
#
# Stops need five minutes in one place to count, so each dwell is real time (DWELL seconds,
# default 6 minutes). Drives run at SPEED metres per second (default 400, a few minutes each).
# Points are stamped with the real time, so the app needs a trip with a day today and tracking
# on (not a pinned clock); see Handoff 5 in docs/HANDOFF.md.
set -euo pipefail

DEVICE="${DEVICE:-booted}"
DWELL="${DWELL:-360}"
SPEED="${SPEED:-400}"

# Synthetic places from the fixture trip.
CAR_HIRE="-42.85,147.5"
SWANSEA="-42.1236,148.0727"
HOLIDAY_PARK="-42.1247,148.2861"

stay() {
  local seconds="${2:-$DWELL}"
  echo "Staying at $1 for ${seconds}s"
  xcrun simctl location "$DEVICE" set "$1"
  sleep "$seconds"
}

drive() {
  echo "Driving $1 → $2 at ${SPEED} m/s"
  xcrun simctl location "$DEVICE" start --speed="$SPEED" --interval=2 "$1" "$2"
  # Rough time for the straight line; the Simulator stops at the last waypoint.
  python3 - "$1" "$2" "$SPEED" <<'PY' | xargs sleep
import math, sys
(a, b), (c, d), speed = (map(float, sys.argv[1].split(","))), (map(float, sys.argv[2].split(","))), float(sys.argv[3])
k = math.pi / 180
x = (d - b) * k * math.cos((a + c) / 2 * k)
y = (c - a) * k
print(int(6371000 * math.hypot(x, y) / speed) + 5)
PY
}

stay "$CAR_HIRE"
drive "$CAR_HIRE" "$SWANSEA"
stay "$SWANSEA" 660      # not in the plan; 10 minutes or more shows as an unplanned stop
drive "$SWANSEA" "$HOLIDAY_PARK"
stay "$HOLIDAY_PARK"
xcrun simctl location "$DEVICE" clear
echo "Done. Open the Log tab."
