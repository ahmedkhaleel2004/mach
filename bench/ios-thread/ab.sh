#!/bin/sh
# Two builds, in turn, in the same minutes (this Mac's load changes all the time, so numbers taken far apart cannot be
# compared), then both side by side. Each run takes the one-simulator lock by itself (see run.sh), so keep the scenario
# list short enough for one run to finish in under ten minutes.
#
#   bench/ios-thread/ab.sh <before.app> <after.app> synth prepare:5,scroll:3 [rounds, default 2]
#   bench/ios-thread/keep.sh <name>      saves the current build as build/apps/<name>.app
set -eu
umask 077
cd "$(dirname "$0")/../.."
before="$1"; after="$2"; box="$3"; spec="$4"; rounds="${5:-2}"
mkdir -p build/results
tag="ab-$(basename "$before" .app)-$(basename "$after" .app)-$box"
rm -f build/results/"$tag"-*.jsonl
a=""; b=""
for round in $(seq "$rounds"); do
  APP="$before" LABEL="$(basename "$before" .app)" OUT="build/results/$tag-a$round.jsonl" bench/ios-thread/run.sh "$box" "$spec" > /dev/null
  APP="$after" LABEL="$(basename "$after" .app)" OUT="build/results/$tag-b$round.jsonl" bench/ios-thread/run.sh "$box" "$spec" > /dev/null
  a="$a${a:+,}build/results/$tag-a$round.jsonl"; b="$b${b:+,}build/results/$tag-b$round.jsonl"
done
echo "load average:$(uptime | sed 's/.*load averages*://')"
shift 4; [ "$#" -gt 0 ] && shift
python3 bench/ios-thread/compare.py "$a" "$b" "$@"
