#!/bin/sh
# Runs the iPhone list benchmarks in a headless simulator and prints a table.
#
#   bench/ios-list/run.sh synth                      every scenario on the made-up mailbox
#   bench/ios-list/run.sh real "scroll invalidate"   some of them on the snapshot of real mail (numbers only)
#   APP=<Mach.app> bench/ios-list/run.sh synth scroll      reuse a build
#   PICTURES=1 bench/ios-list/run.sh synth "scroll memory"       every sender has a (made-up) picture
#
# Scenarios: scroll invalidate swipe loadmore jump switch search memory lab eq. Each starts the app again on a fresh
# copy of the mailbox. ROWS (1000), STEP (points a frame, 120), ROUNDS (5), MEMORY_ROWS (3000), LAB (which lab rows),
# CLASSES=1 (also count which kinds of layer are made and drawn).
. "$(dirname "$0")/lib.sh"
what="${2:-scroll invalidate swipe loadmore jump switch search memory}"
suffix=""
if [ -n "${PICTURES:-}" ]; then
  fresh
  PICTURES="$root/build/run/ios-list-pictures-$box"
  [ -d "$PICTURES" ] || /usr/bin/python3 "$root/bench/ios-list/seed_avatars.py" "$data/mail.sqlite" "$PICTURES" >/dev/null
  suffix="-pictures"
fi
for name in $what; do
  case "$name" in
    scroll) spec="all,scroll" ;;
    loadmore) spec="all,loadmore" ;;
    memory) spec="all,memory" ;;
    lab) spec="all,lab" ;;
    *) spec="$name" ;;
  esac
  fresh; take
  launch "$spec"
  await list_bench_done 1 2700 || true
  stop
  release
  cp "$log" "$out/$name$suffix.jsonl"
done
echo "load average:$(uptime | sed 's/.*load averages*://')"
/usr/bin/python3 "$root/bench/ios-list/summary.py" "$out" $(for name in $what; do printf '%s ' "$name$suffix"; done)
