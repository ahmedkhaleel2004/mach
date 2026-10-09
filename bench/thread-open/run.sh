#!/bin/sh
# Times opening conversations in the Mac benchmark app, on a throwaway copy of a mailbox.
#
#   bench/thread-open/run.sh synth            every scenario, 20 opens of each shape
#   bench/thread-open/run.sh real opens:30    one scenario: opens | unread | rapid | memory | paint (| all)
#   bench/thread-open/run.sh real verify      checks the quick message classifying against the patterns, on all mail
#   APP=<path to Mach.app> ...           skip the build
#
# `paint:3` is the only scenario that shows the window: three times, for under a second each, without taking the
# keyboard. Everything else runs with the window wherever `open -g` left it and times "laid out", not "painted".
# Prints a table (numbers only). The raw lines stay in build/run/thread-open-<mailbox>/bench.jsonl.
set -eu
umask 077
cd "$(dirname "$0")/../.."
box="${1:-synth}"
spec="${2:-all:20}"
export MACH_BENCH_DATA="${MACH_BENCH_DATA:-$PWD/build/data}"
app="${APP:-$(DD=build/dd-mac bench/build.sh mac)}"
dir="$PWD/build/run/thread-open-$box"
channel=com.ahmedkhaleel.machbench.thread-open
bench/data.sh fresh "$box" "$dir"
sqlite3 "$dir/mail.sqlite" < bench/thread-open/pick.sql > "$dir/bench-threads.tsv"
sqlite3 -tabs "$dir/mail.sqlite" "select accountId, id from thread" > "$dir/bench-all-threads.tsv"
before="$(pgrep -f "$app/Contents/MacOS/Mach" || true)"
open -g -n "$app" --env MACH_DATA_DIR="$dir" --env MACH_OFFLINE=1 --env MACH_DEBUG_CHANNEL="$channel"
pid=""
for _ in $(seq 100); do
  # The one that was not there a moment ago (an earlier run's app may still be on its way out).
  pid="$(pgrep -f "$app/Contents/MacOS/Mach" | grep -v -x -F "${before:-none}" | tail -1 || true)"
  [ -n "$pid" ] && grep -q thread_web_ready "$dir/bench.jsonl" 2>/dev/null && break
  sleep 0.2
done
[ -n "$pid" ] || { echo "the benchmark app did not start"; exit 1; }
# Only ever the process started here, by its id.
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1.5
swift bench/thread-open/send.swift "$channel" "bench:$spec"
for _ in $(seq 1800); do
  grep -q 'thread_bench_done\|thread_bench_error' "$dir/bench.jsonl" && break
  kill -0 "$pid" 2>/dev/null || { echo "the benchmark app quit early"; break; }
  sleep 0.5
done
kill "$pid" 2>/dev/null || true
trap - EXIT
python3 bench/thread-open/report.py "$dir/bench.jsonl"
