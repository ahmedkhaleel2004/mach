#!/bin/sh
# Reading mail on the iPhone, measured in a simulator of its own (BlitzBench-ios-thread, headless, never Simulator.app).
#
#   bench/ios-thread/run.sh synth                         every scenario on the made-up mailbox
#   bench/ios-thread/run.sh real opens:10,fit             chosen scenarios on the copy of real mail (numbers only)
#   APP=<simulator Mach.app> bench/ios-thread/run.sh synth prepare:5      skip the build
#   LIMIT=<seconds> ...                                   give up after this long (default 540)
#   INSPECT='<command>' ... synth hold:3                  at each of `hold`'s three stops runs the command with the page
#                                                         process's id and the stop's number (vmmap, heap, sample)
#   WEBENV='Malloc=1' ...                                 environment for the page's process (space separated NAME=value)
#   OUT=<file> ...                                        also keep the raw lines there
#
# Scenarios (`name` or `name:count`), comma separated:
#   opens unread     tap to laid out and painted, per shape (the Mac harness's scenarios, in the simulator)
#   fit              the first frame of each shape: is a wide message already shrunk to the screen
#   prepare          a long conversation's collapsed messages being built in the background
#   scroll           a quick scroll through a heavy message: the page's frames and processor time
#   back             the back swipe: views drawn again and processor time per frame
#   heavy            the page process's memory after the 50 largest newsletters (heavy:3 = three rounds)
#   reclaim          the page's process killed, and the conversation drawn again
#   next             archive with a conversation open: the next one shown
#   pictures         the app's own picture addresses: requests and time per answer
#
# Only two simulators may be booted on this Mac at a time: the run waits for /tmp/blitz-sim.lock or
# /tmp/blitz-sim2.lock, holds it for at most
# LIMIT seconds (keep each run under ten minutes: split long lists of scenarios) and always stops the app and gives
# the lock back, also when it fails. A lock older than 15 minutes was left by a script that died, and is taken.
#
# Simulator wall-clock times are noisy and are not a phone's: compare two builds with ab.sh, and trust counts and
# processor time first. The web view blocks every network request (BLITZ_OFFLINE=1).
set -eu
umask 077
cd "$(dirname "$0")/../.."
box="${1:-synth}"
spec="${2:-opens:10,unread:10,fit,prepare:5,scroll:3,back:10,pictures,next:12,reclaim:5,heavy:2}"
export BLITZ_BENCH_DATA="${BLITZ_BENCH_DATA:-$PWD/build/data}"
app="${APP:-$(DD="${DD:-build/dd-ios-thread}" bench/build.sh ios)}"
name=BlitzBench-ios-thread
bundle=app.blitzbench.ios
dir="$PWD/build/run/ios-thread-$box"
bench/data.sh fresh "$box" "$dir"
sqlite3 "$dir/mail.sqlite" < bench/thread-open/pick.sql > "$dir/bench-threads.tsv"
if [ "$box" = synth ]; then
  # Made-up mail with real pictures in it, and a made-up picture for every sender the benchmark meets.
  [ -x Core/.build/release/blitzbench ] || (cd Core && swift build -c release --product blitzbench > /dev/null 2>&1)
  Core/.build/release/blitzbench pictures "$dir" >> "$dir/bench-threads.tsv"
  python3 bench/ios-thread/seed_avatars.py "$dir/mail.sqlite" "$dir/bench-threads.tsv" "$dir/bench-avatars" > /dev/null
fi
device="$(xcrun simctl list devices | grep "$name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
[ -n "$device" ] || device="$(xcrun simctl create "$name" "iPhone 18 Pro")"
# Booting is the heavy part, so the simulator is booted once and left booted (shut it down yourself at the very end:
# xcrun simctl shutdown BlitzBench-ios-thread). The lock only covers the time the app is measuring.
xcrun simctl bootstatus "$device" -b > /dev/null
xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
xcrun simctl install "$device" "$app"
lock=""
stop() {
  xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
  [ -z "$lock" ] || rm -rf "$lock"
  lock=""
}
trap stop EXIT
trap 'exit 1' INT TERM HUP
while [ -z "$lock" ]; do
  for candidate in /tmp/blitz-sim.lock /tmp/blitz-sim2.lock; do
    # Left behind by a script that died more than 15 minutes ago.
    [ -z "$(find "$candidate" -maxdepth 0 -mmin +15 2>/dev/null)" ] || rm -rf "$candidate"
    if mkdir "$candidate" 2>/dev/null; then
      lock="$candidate"
      break
    fi
  done
  [ -n "$lock" ] || sleep 10
done
echo "$$ ios-thread" > "$lock/owner"
deadline=$(( $(date +%s) + ${LIMIT:-540} ))
# The system hands a variable named __XPC_<name> to the processes an app starts, as <name>.
for pair in ${WEBENV:-}; do export "SIMCTL_CHILD___XPC_$pair"; done
SIMCTL_CHILD_BLITZ_DATA_DIR="$dir" SIMCTL_CHILD_BLITZ_OFFLINE=1 SIMCTL_CHILD_BLITZ_THREAD_BENCH="$spec" \
  SIMCTL_CHILD_BLITZ_AVATAR_DIR="$dir/bench-avatars" SIMCTL_CHILD_BLITZ_DEBUG_CHANNEL=app.blitzbench.ios-thread \
  xcrun simctl launch "$device" "$bundle" -noPrompts YES > /dev/null
stops=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  grep -q 'thread_bench_all_done\|thread_bench_error' "$dir/bench.jsonl" 2>/dev/null && break
  if [ -n "${INSPECT:-}" ]; then
    now="$(grep -c '"thread_hold"' "$dir/bench.jsonl" 2>/dev/null || true)"
    if [ "${now:-0}" -gt "$stops" ]; then
      stops="$now"
      pid="$(grep '"thread_hold"' "$dir/bench.jsonl" | tail -1 | sed -E 's/.*"ms":([0-9]+).*/\1/')"
      sh -c "$INSPECT" inspect "$pid" "$stops" || true
    fi
  fi
  sleep 0.5
done
grep -q 'thread_bench_all_done' "$dir/bench.jsonl" 2>/dev/null || echo "NOT FINISHED within ${LIMIT:-540} s: the tables below are partial"
stop
trap - EXIT
# Pictures of made-up mail are kept to compare; pictures of real mail are deleted here and now.
if [ "$box" = synth ] && [ -d "$dir/shots" ]; then
  rm -rf "build/results/shots-${LABEL:-last}"
  mkdir -p build/results
  cp -R "$dir/shots" "build/results/shots-${LABEL:-last}"
else
  rm -rf "$dir/shots"
fi
[ -z "${OUT:-}" ] || cp "$dir/bench.jsonl" "$OUT"
echo "load average:$(uptime | sed 's/.*load averages*://')"
python3 bench/thread-open/report.py "$dir/bench.jsonl"
python3 bench/ios-thread/report.py "$dir/bench.jsonl"
