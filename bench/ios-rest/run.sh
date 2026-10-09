#!/bin/sh
# Runs the "everything else on the iPhone" benchmarks (writing mail, search field, overlays, memory, idle) in a
# headless simulator of its own (MachBench-ios-rest; never Simulator.app, never anyone else's device).
#
#   bench/ios-rest/run.sh synth "compose search overlays"     scenarios, in order, in one launch
#   bench/ios-rest/run.sh real compose                        numbers only are printed for real mail
#   APP=<Mach.app> bench/ios-rest/run.sh synth memory:600      reuse a build; memory with a 10 minute idle
#   OUT=<file.jsonl> ...                                      also keep the raw lines there
#   LIMIT=<quarter seconds> ...                               how long to wait for the app (default 2000 = 8 minutes)
#   SHOTS=<folder> bench/ios-rest/run.sh synth shots          a picture of every screen (made-up mailbox only)
#   FOOTPRINT=<folder> ... memory                             what the memory is made of at each point
#   PICTURES=1 ... memory                                     every sender has a (made-up) picture, as in real use
#
# Scenarios: compose[:rounds] reply[:rounds] send[:rounds] search[:rounds] overlays[:rounds] memory[:idle seconds]
# idle[:seconds] shots. Simulator time is not phone time: trust the counts (n_*) and compare processor time
# before and after.
set -eu
umask 077
cd "$(dirname "$0")/../.."
box="${1:-synth}"
spec="${2:-compose reply send search overlays}"
export MACH_BENCH_DATA="${MACH_BENCH_DATA:-$PWD/build/data}"
app="${APP:-$(DD=build/dd-ios-rest MACH_DATA_DIR=/nonexistent bench/build.sh ios | tail -1)}"
bundle=com.ahmedkhaleel.machbench.ios
dir="$PWD/build/run/ios-rest-$box"
bench/data.sh fresh "$box" "$dir"
# Which conversations to reply to, by shape only (the 200-message one, the 150 KB newsletter).
sqlite3 "$dir/mail.sqlite" < bench/thread-open/pick.sql > "$dir/bench-threads.tsv"
# One simulator at a time on this Mac: waits for the lock, boots, and gives both back when this script ends.
. bench/ios-rest/lock.sh
sim_take
xcrun simctl terminate "$device" $bundle 2>/dev/null || true
xcrun simctl install "$device" "$app"
# "-noPrompts YES": the app does not ask for notifications, whose system alert would cover the screen.
# PICTURES=1 gives every sender a made-up picture first; otherwise the picture folder is empty (initials only).
[ "${PICTURES:-0}" != 1 ] || python3 bench/ios-rest/seed_avatars.py "$dir/mail.sqlite" "$dir/avatars" > /dev/null
pid=$(SIMCTL_CHILD_MACH_DATA_DIR="$dir" SIMCTL_CHILD_MACH_OFFLINE=1 SIMCTL_CHILD_MACH_REST_BENCH="$spec" SIMCTL_CHILD_MACH_AVATAR_DIR="$dir/avatars" \
  xcrun simctl launch "$device" $bundle -noPrompts YES | sed 's/.*: //')
seen=0
for _ in $(seq ${LIMIT:-2000}); do
  grep -q 'rest_bench_done' "$dir/bench.jsonl" 2>/dev/null && break
  # The app asks for a picture of the screen by writing a line, and waits for the answer.
  if [ "$box" = synth ] && [ -n "${SHOTS:-}" ]; then
    for shot in $(grep '"metric":"shot"' "$dir/bench.jsonl" 2>/dev/null | sed -E 's/.*"name":"([a-z_0-9]*)".*/\1/'); do
      [ -f "$dir/shot-$shot.taken" ] && continue
      mkdir -p "$SHOTS"; sleep 0.4
      xcrun simctl io "$device" screenshot "$SHOTS/$shot.png" >/dev/null 2>&1
      : > "$dir/shot-$shot.taken"
    done
  fi
  # SAMPLE=<file> [SAMPLE_AT=<metric>]: where the main thread's time goes, for five seconds from the moment that
  # metric is first written (default: the first compose open, so the sample covers typing).
  if [ -n "${SAMPLE:-}" ] && [ ! -f "$dir/sampling" ] && grep -q "\"metric\":\"${SAMPLE_AT:-compose.open.cold}\"" "$dir/bench.jsonl" 2>/dev/null; then
    : > "$dir/sampling"; mkdir -p "$(dirname "$SAMPLE")"
    sample "$pid" 5 -mayDie -file "$SAMPLE" >/dev/null 2>&1 &
  fi
  # What the memory is made of, seen from outside, each time the app notes a memory figure.
  if [ -n "${FOOTPRINT:-}" ]; then
    now=$(grep -c '"metric":"mem\.[a-z]' "$dir/bench.jsonl" 2>/dev/null || true)
    if [ "${now:-0}" -gt "$seen" ]; then seen=$now; mkdir -p "$FOOTPRINT"; footprint "$pid" > "$FOOTPRINT/$seen.txt" 2>/dev/null || true; fi
  fi
  sleep 0.25
done
xcrun simctl terminate "$device" $bundle 2>/dev/null || true
[ -z "${OUT:-}" ] || { mkdir -p "$(dirname "$OUT")"; grep -v '"metric":"shot' "$dir/bench.jsonl" > "$OUT"; }
python3 bench/ios-rest/summary.py "$dir/bench.jsonl"
