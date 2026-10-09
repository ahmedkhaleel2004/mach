#!/bin/sh
# Two builds, run turn and turn about in the same minutes, so whatever else the Mac is doing hits both alike.
#
#   bench/ios-rest/ab.sh <before.app> <after.app> synth "compose:4" [turns]
#
# Prints one table per build from all its turns together. Keep copies of the builds: `cp -R <Mach.app> build/apps/x.app`.
set -eu
cd "$(dirname "$0")/../.."
a="$1"; b="$2"; box="${3:-synth}"; spec="${4:-compose:4}"; turns="${5:-3}"
out="build/out/ab-$$"
mkdir -p "$out"
# The lock is held once for all the turns (keep the whole thing under ten minutes: few rounds, few turns).
. bench/ios-rest/lock.sh
sim_take
export SIM_LOCK_HELD=1
: > "$out/a.jsonl"; : > "$out/b.jsonl"
i=0
while [ "$i" -lt "$turns" ]; do
  APP="$a" OUT="$out/turn.jsonl" bench/ios-rest/run.sh "$box" "$spec" > /dev/null; cat "$out/turn.jsonl" >> "$out/a.jsonl"
  APP="$b" OUT="$out/turn.jsonl" bench/ios-rest/run.sh "$box" "$spec" > /dev/null; cat "$out/turn.jsonl" >> "$out/b.jsonl"
  i=$((i + 1))
done
echo "== before ($a)"; python3 bench/ios-rest/summary.py "$out/a.jsonl"
echo "== after ($b)"; python3 bench/ios-rest/summary.py "$out/b.jsonl"
echo "load average:$(uptime | sed 's/.*load averages*://')"
