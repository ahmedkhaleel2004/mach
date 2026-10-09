#!/bin/sh
# The headless compose benchmark on throwaway copies of both mailboxes. Prints JSON lines (numbers only).
#   bench/lean/core.sh            needs BLITZ_BENCH_DATA; builds blitzbench first
set -eu
cd "$(dirname "$0")/../.."
umask 077
(cd Core && swift build -c release --product blitzbench >/dev/null 2>&1)
for mailbox in synth real; do
  bench/data.sh fresh "$mailbox" "build/lean/core-$mailbox"
  Core/.build/release/blitzbench compose "build/lean/core-$mailbox" | sed "s/^{/{\"mailbox\":\"$mailbox\",/"
done
