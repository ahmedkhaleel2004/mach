#!/bin/sh
# The headless compose benchmark on throwaway copies of both mailboxes. Prints JSON lines (numbers only).
#   bench/lean/core.sh            needs MACH_BENCH_DATA; builds machbench first
set -eu
cd "$(dirname "$0")/../.."
umask 077
(cd Core && swift build -c release --product machbench >/dev/null 2>&1)
for mailbox in synth real; do
  bench/data.sh fresh "$mailbox" "build/lean/core-$mailbox"
  Core/.build/release/machbench compose "build/lean/core-$mailbox" | sed "s/^{/{\"mailbox\":\"$mailbox\",/"
done
