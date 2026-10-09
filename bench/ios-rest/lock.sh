# Sourced by the scripts here. At most two simulators may be booted on this Mac at a time (four at once made every
# number useless), so whoever measures holds /tmp/blitz-sim.lock or /tmp/blitz-sim2.lock, and gives it back, with its app stopped,
# when the script ends for any reason. A lock older than 15 minutes belongs to something that died.
sim_name=BlitzBench-ios-rest
sim_locks="/tmp/blitz-sim.lock /tmp/blitz-sim2.lock"
sim_lock=

sim_device() {
  found="$(xcrun simctl list devices | grep "$sim_name (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)"
  [ -n "$found" ] || found="$(xcrun simctl create "$sim_name" "iPhone 18 Pro")"
  echo "$found"
}

# Booting is what loads the Mac most, so the simulator is left booted between turns: only the app is stopped.
# Shut it down by hand when the work is over: xcrun simctl shutdown BlitzBench-ios-rest
sim_release() {
  xcrun simctl terminate "$device" app.blitzbench.ios 2>/dev/null || true
  [ -n "$sim_lock" ] && [ "$(cat "$sim_lock/owner" 2>/dev/null)" = "$$ ios-rest" ] && rm -rf "$sim_lock"
  return 0
}

# Takes whichever of the two locks is free (waiting if neither is), boots the simulator, and arranges for both to
# be undone when the script ends. A script started by one that already holds a lock (SIM_LOCK_HELD=1) only boots.
sim_take() {
  device="$(sim_device)"
  if [ "${SIM_LOCK_HELD:-0}" != 1 ]; then
    while [ -z "$sim_lock" ]; do
      for lock in $sim_locks; do
        [ -z "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ] || rm -rf "$lock"
        if mkdir "$lock" 2>/dev/null; then sim_lock="$lock"; break; fi
      done
      [ -n "$sim_lock" ] || sleep 10
    done
    echo "$$ ios-rest" > "$sim_lock/owner"
    trap sim_release EXIT INT TERM
  fi
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" > /dev/null
}
