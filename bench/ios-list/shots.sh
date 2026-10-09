#!/bin/sh
# Takes the same screenshots of the list on the made-up mailbox every time, to check that a change did not move a
# pixel: every row style, pictures on and off and present, ticked rows, a swipe held part of the way in each of the
# three designs, the combined inbox, one account, search, the empty list, the list switcher, a toast, light and dark.
#
#   APP=<Mach.app> bench/ios-list/shots.sh <folder>
#   bench/ios-list/shots.sh diff <folder a> <folder b>         byte-compares the two sets
if [ "${1:-}" = diff ]; then
  same=0; count=0
  for f in "$2"/*.png; do
    count=$((count + 1))
    if cmp -s "$f" "$3/$(basename "$f")"; then :; else echo "DIFFERENT $(basename "$f")"; same=1; fi
  done
  [ "$same" = 0 ] && echo "all $count screenshots are byte-identical"
  exit $same
fi
target="$1"
. "$(dirname "$0")/lib.sh" synth
mkdir -p "$target"
pictures="$root/build/run/ios-list-pictures-synth"
fresh
[ -d "$pictures" ] || /usr/bin/python3 "$root/bench/ios-list/seed_avatars.py" "$data/mail.sqlite" "$pictures" >/dev/null
# The simulator is taken for one look at a time, and given back in between.
ready() {
  take
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl ui "$udid" appearance "$look"
}
shot() { sleep 0.3; xcrun simctl io "$udid" screenshot "$target/$look-$1.png" >/dev/null 2>&1; }
# start <name> [app arguments]: a fresh copy of the mailbox and a fresh start, so every set begins the same.
start() { set="$1"; shift; fresh; stop; launch "" "$@"; sleep 2.5; }

for look in light dark; do
  ready
  start main
  shot list
  key tick; shot ticked; key untick
  for hold in hold-left-40 hold-left-100 hold-right-40 hold-right-100; do key "$hold"; shot "swipe1-$hold"; key drop; done
  key toast; shot toast; key toastGone
  key down; shot scrolled; key top
  key all; shot all-mail
  key snoozed; shot empty
  key home
  key one; shot one-account; key every
  key lists; shot switcher; key lists
  key search; shot search; key searchEnd
  stop; release; ready
  for style in 2 3; do
    start "swipe$style" -swipeStyle "$style"
    for hold in hold-left-40 hold-left-100 hold-right-100; do key "$hold"; shot "swipe$style-$hold"; key drop; done
  done
  for style in 0 2 3 4; do
    start "row$style" -rowStyle "$style"
    shot "row$style"
    key tick; shot "row$style-ticked"; key untick
    key hold-left-100; shot "row$style-swipe"; key drop
  done
  stop; release; ready
  start plain -showAvatars NO
  shot no-pictures
  key tick; shot no-pictures-ticked; key untick
  PICTURES="$pictures" start faces
  shot faces
  key tick; shot faces-ticked; key untick
  key hold-right-100; shot faces-swipe; key drop
  PICTURES=""
  stop
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" clear
  release
done
echo "$target"
