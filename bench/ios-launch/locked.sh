#!/bin/sh
# Runs bench.py commands while holding the machine-wide simulator lock, so only one simulator is ever booted.
#
#   bench/ios-launch/locked.sh launch synth 15
#   bench/ios-launch/locked.sh -f <file>       one bench.py command a line: `<output file> <switch for side B of an ab, or -> <arguments...>`
#
# Waits for /tmp/blitz-sim.lock or /tmp/blitz-sim2.lock (taking one over if its owner has been gone 15 minutes), gives the work at most
# LIMIT seconds (default 540), and always gives the lock back, even when cut short.
set -u
cd "$(dirname "$0")/../.."
# Two simulators may run at once, so there are two locks: whichever is free.
lock=""
while [ -z "$lock" ]; do
  for candidate in /tmp/blitz-sim.lock /tmp/blitz-sim2.lock; do
    if [ -n "$(find "$candidate" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then rm -rf "$candidate"; fi
    if mkdir "$candidate" 2>/dev/null; then lock="$candidate"; break; fi
  done
  [ -n "$lock" ] || sleep 5
done
echo "$$ ios-launch" > "$lock/owner"
# The simulator stays booted between turns (booting is the expensive part): `bench.py down` at the very end.
release() {
  rm -rf "$lock"
}
trap 'release; exit 1' INT TERM HUP
if [ "${1:-}" = -f ]; then
  ( while read -r out switch rest; do
      [ -n "$out" ] || continue
      [ "$switch" = - ] && switch=""
      # shellcheck disable=SC2086
      SWITCH_B="$switch" RAW="$(basename "$out" .txt).jsonl" python3 bench/ios-launch/bench.py $rest > "$out" 2>&1
    done < "$2" ) &
else
  python3 bench/ios-launch/bench.py "$@" &
fi
child=$!
( sleep "${LIMIT:-540}"; pkill -P "$child" 2>/dev/null; kill "$child" 2>/dev/null ) &
timer=$!
wait "$child"
status=$?
kill "$timer" 2>/dev/null
release
exit "$status"
