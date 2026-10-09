#!/bin/sh
# Runs sections with an older build of machbench and with the current one, back to back, and prints the change.
# This Mac is rarely quiet, so a number is only trusted against a baseline taken in the same minute.
#
#   cp Core/.build/release/machbench build/machbench-base     (once, on the commit to compare against)
#   bench/store-db/ab.sh synth|real section...
set -eu
umask 077
cd "$(dirname "$0")/../.."
mailbox="$1"; shift
old="${OLD:-build/machbench-base}"
(cd Core && swift build -c release --product machbench >/dev/null 2>&1)
mkdir -p build/store-db
work="build/store-db/ab-$mailbox"
: > "build/store-db/$mailbox-ab-old.jsonl"
: > "build/store-db/$mailbox-ab-new.jsonl"
for section in "$@"; do
  bench/data.sh fresh "$mailbox" "$work"
  "$old" store "$work" "$section" >> "build/store-db/$mailbox-ab-old.jsonl"
  bench/data.sh fresh "$mailbox" "$work"
  Core/.build/release/machbench store "$work" "$section" >> "build/store-db/$mailbox-ab-new.jsonl"
done
rm -rf "$work"
bench/store-db/compare.py "build/store-db/$mailbox-ab-old.jsonl" "build/store-db/$mailbox-ab-new.jsonl"
