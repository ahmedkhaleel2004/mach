#!/bin/sh
# Pictures of every screen this frontier touches (compose, suggestions, toast, each overlay, search), taken on the
# made-up mailbox, to prove a change did not move a pixel.
#
#   APP=<Mach.app> bench/ios-rest/shots.sh <folder>              take them
#   bench/ios-rest/shots.sh compare <folder-before> <folder-after>    compare byte for byte, then pixel by pixel
#
# The clock in the status bar is frozen and the text cursor is hidden while they are taken, since both change by
# themselves from one moment to the next.
set -eu
cd "$(dirname "$0")/../.."
if [ "${1:-}" = compare ]; then
  status=0
  for before in "$2"/*.png; do
    name=$(basename "$before")
    if cmp -s "$before" "$3/$name"; then echo "same      $name"; else
      # Not the same bytes: say how many pixels differ and where (a PNG can differ in bytes and still be the same picture).
      uv run --quiet --with pillow python3 bench/ios-rest/pixels.py "$before" "$3/$name" || status=1
    fi
  done
  exit $status
fi
out="$1"
. bench/ios-rest/lock.sh
sim_take
export SIM_LOCK_HELD=1
xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
xcrun simctl ui "$device" appearance light >/dev/null 2>&1 || true
rm -rf "$out"
SHOTS="$out" bench/ios-rest/run.sh synth shots > /dev/null
ls "$out"
