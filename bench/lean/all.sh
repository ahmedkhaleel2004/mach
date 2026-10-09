#!/bin/sh
# Runs every Mac benchmark of the `lean` frontier on both mailboxes and appends the JSON lines to a file.
#   bench/lean/all.sh <output.jsonl> [launch memory idle compose]
# Needs MACH_BENCH_DATA and the benchmark app (bench/build.sh mac). Takes about 20 minutes with everything.
set -eu
cd "$(dirname "$0")/../.."
out="$1"; shift
kinds="${*:-launch compose memory idle}"
umask 077
for kind in $kinds; do
  for mailbox in synth real; do
    python3 bench/lean/lean.py "$kind" "$mailbox" >> "$out"
  done
done
