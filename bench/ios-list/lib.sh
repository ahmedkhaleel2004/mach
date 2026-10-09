# Shared by the iPhone list benchmark scripts. Simulator only, in a device of its own (BlitzBench-ios-list), never
# Simulator.app. Simulator numbers are not device numbers: trust the counts first, then main-thread processor time
# compared between two builds run in turn (ab.sh), and the wall clock last.
set -eu
umask 077
cd "$(dirname "$0")/../.."
root="$PWD"
bundle=app.blitzbench.ios
export BLITZ_BENCH_DATA="${BLITZ_BENCH_DATA:-$PWD/build/data}"
mkdir -p build && chmod 700 build

udid=$(xcrun simctl list devices | sed -n 's/.*BlitzBench-ios-list (\([0-9A-F-]*\)).*/\1/p' | head -1)
if [ -z "$udid" ]; then udid=$(xcrun simctl create BlitzBench-ios-list "iPhone 18 Pro"); fi

# APP=<path> skips the build. The build happens before the simulator is taken.
app="${APP:-}"
if [ -z "$app" ]; then app=$(BLITZ_DATA_DIR=/nonexistent DD=build/dd-ios-list bench/build.sh ios | tail -1); fi

# Only two simulators may be booted on this Mac at a time, whoever they belong to: two locks, either will do.
# `take` waits for one, boots ours if needed and installs the app; `release` stops the app and gives the lock back. A lock
# older than 15 minutes was left by something that died. Hold one for a single scenario at a time.
lock=""
held=0
take() {
  while [ "$held" = 0 ]; do
    for candidate in /tmp/blitz-sim.lock /tmp/blitz-sim2.lock; do
      if mkdir "$candidate" 2>/dev/null; then lock="$candidate"; held=1; break; fi
      age=$(( $(date +%s) - $(stat -f %m "$candidate" 2>/dev/null || date +%s) ))
      [ "$age" -gt 900 ] && rm -rf "$candidate"
    done
    [ "$held" = 1 ] || sleep 10
  done
  echo "$$ ios-list" > "$lock/owner"
  # Booting is the heavy part: the simulator is booted once and left booted (shut it down by hand at the very end).
  if ! xcrun simctl list devices | grep "$udid" | grep -q Booted; then
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
  fi
  xcrun simctl install "$udid" "$app"
}
release() {
  [ "$held" = 1 ] || return 0
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  rm -rf "$lock"; held=0
}
trap release EXIT
trap 'release; exit 1' INT TERM

box="${1:-synth}"
data="$root/build/run/ios-list-$box"
log="$data/bench.jsonl"
out="$root/build/run/ios-list-$box-out"
mkdir -p "$out"

fresh() { bench/data.sh fresh "$box" "$data"; }

lines() { n=$(grep -c "\"$1\"" "$log" 2>/dev/null) || n=0; echo "${n:-0}"; }

# Waits until the log holds at least $2 lines naming $1.
await() {
  tries=0
  while [ "$(lines "$1")" -lt "$2" ]; do
    tries=$((tries + 1)); [ "$tries" -gt "${3:-1500}" ] && { echo "timed out waiting for $1" >&2; return 1; }
    sleep 0.2
  done
}

# launch <scenarios> [app arguments...]: starts the app on the working copy. PICTURES=<folder> gives senders pictures.
launch() {
  spec="$1"; shift
  SIMCTL_CHILD_BLITZ_DATA_DIR="$data" SIMCTL_CHILD_BLITZ_OFFLINE=1 SIMCTL_CHILD_BLITZ_DEBUG_CHANNEL=app.blitzbench.ios-list \
    SIMCTL_CHILD_BLITZ_LIST_BENCH="$spec" SIMCTL_CHILD_BLITZ_AVATAR_DIR="${PICTURES:-$root/build/run/ios-list-no-pictures}" \
    SIMCTL_CHILD_BLITZ_LIST_ROWS="${ROWS:-1000}" SIMCTL_CHILD_BLITZ_LIST_STEP="${STEP:-120}" SIMCTL_CHILD_BLITZ_LIST_ROUNDS="${ROUNDS:-5}" \
    SIMCTL_CHILD_BLITZ_LIST_MEMORY_ROWS="${MEMORY_ROWS:-3000}" SIMCTL_CHILD_BLITZ_LIST_LAB="${LAB:-}" SIMCTL_CHILD_BLITZ_LIST_CLASSES="${CLASSES:-}" \
    xcrun simctl launch "$udid" "$bundle" -noPrompts YES "$@" >/dev/null
}

stop() { xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true; sleep 0.4; }

# Sends one command to the app and waits until it has been drawn.
key() {
  before=$(lines "name\":\"$1")
  xcrun simctl spawn "$udid" notifyutil -p "app.blitzbench.list.$1"
  await "name\":\"$1" $((before + 1)) 100
}
