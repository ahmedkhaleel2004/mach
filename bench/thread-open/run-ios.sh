#!/bin/sh
# The same thread-open benchmark in an iPhone simulator of its own (never the one already booted, never Simulator.app).
#
#   bench/thread-open/run-ios.sh synth opens:15
#   APP=<path to the simulator Mach.app> ...     skip the build
set -eu
umask 077
cd "$(dirname "$0")/../.."
box="${1:-synth}"
spec="${2:-opens:15}"
export MACH_BENCH_DATA="${MACH_BENCH_DATA:-$PWD/build/data}"
app="${APP:-$(DD=build/dd-ios bench/build.sh ios)}"
name=MachBench-thread-open
dir="$PWD/build/run/thread-open-ios-$box"
bench/data.sh fresh "$box" "$dir"
sqlite3 "$dir/mail.sqlite" < bench/thread-open/pick.sql > "$dir/bench-threads.tsv"
device="$(xcrun simctl list devices | grep "$name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
[ -n "$device" ] || device="$(xcrun simctl create "$name" "iPhone 18 Pro")"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" > /dev/null
trap 'xcrun simctl shutdown "$device" 2>/dev/null || true' EXIT
xcrun simctl install "$device" "$app"
SIMCTL_CHILD_MACH_DATA_DIR="$dir" SIMCTL_CHILD_MACH_OFFLINE=1 SIMCTL_CHILD_MACH_THREAD_BENCH="$spec" \
  xcrun simctl launch "$device" com.ahmedkhaleel.machbench.ios > /dev/null
for _ in $(seq 1200); do
  grep -q 'thread_bench_done\|thread_bench_error' "$dir/bench.jsonl" 2>/dev/null && break
  sleep 0.5
done
xcrun simctl terminate "$device" com.ahmedkhaleel.machbench.ios 2>/dev/null || true
xcrun simctl shutdown "$device" 2>/dev/null || true
trap - EXIT
python3 bench/thread-open/report.py "$dir/bench.jsonl"
