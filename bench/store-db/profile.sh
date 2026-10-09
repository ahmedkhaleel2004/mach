#!/bin/sh
# Samples one store operation in a loop and prints where its time goes.
#   bench/store-db/profile.sh synth list|modify|save|known|search|thread
set -eu
umask 077
cd "$(dirname "$0")/../.."
work="build/store-db/profile-$1"
bench/data.sh fresh "$1" "$work"
Core/.build/release/machbench store "$work" spin "$2" &
pid=$!
sleep 5
sample "$pid" 4 -mayDie -file "build/store-db/profile-$1-$2.txt" >/dev/null 2>&1 || true
wait "$pid" || true
rm -rf "$work"
# The heaviest frames, by time spent in the function itself.
sed -n '/Sort by top of stack/,/^$/p' "build/store-db/profile-$1-$2.txt" | head -45
grep -E '^ +[+!:| ]+[0-9]+ (Store\.|specialized Store|closure .* in Store|static Store|HTMLText|static EmailAddress|MIMEWords)' "build/store-db/profile-$1-$2.txt" | sed -E 's/^[ +!:|]+//; s/  \(in .*//' | sort -k2 | awk '{n[$2" "$3" "$4]+=$1} END {for (k in n) print n[k], k}' | sort -rn | head -25
