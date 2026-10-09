#!/bin/sh
# Builds once and runs every thread-open measurement on both mailboxes, saving the tables under build/results.
#
#   bench/thread-open/all.sh <label> [opens] [mailboxes]      e.g. all.sh baseline 20 "synth real"
set -eu
umask 077
cd "$(dirname "$0")/../.."
label="${1:-run}"
count="${2:-20}"
boxes="${3:-synth real}"
APP="$(DD=build/dd-mac bench/build.sh mac)"
export APP
mkdir -p build/results
for box in $boxes; do
  bench/thread-open/run.sh "$box" "all:$count" > "build/results/$label-$box.md"
  rm -rf "build/results/$label-$box-shots"
  # Pictures of made-up mail are kept to compare by eye; pictures of real mail are thrown away with the working copy.
  [ "$box" = synth ] && cp -R "build/run/thread-open-$box/shots" "build/results/$label-$box-shots" 2>/dev/null || true
  bench/thread-open/run.sh "$box" "paint:4" > "build/results/$label-$box-paint.md"
done
echo "tables: build/results/$label-*.md"
