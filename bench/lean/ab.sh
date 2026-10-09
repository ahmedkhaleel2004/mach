#!/bin/sh
# Compares two builds of the benchmark app on launch time and scrolling, taking turns so that whatever else this Mac
# is doing hits both alike.
#   bench/lean/ab.sh <A.app> <B.app> [rounds]      prints JSON lines tagged "build": "A" or "B"
set -eu
cd "$(dirname "$0")/../.."
a="$1"; b="$2"; rounds="${3:-3}"
umask 077
i=0
while [ "$i" -lt "$rounds" ]; do
  for mailbox in synth real; do
    APP="$a" python3 bench/lean/lean.py launch "$mailbox" 8 | sed 's/^{/{"build": "A", /'
    APP="$b" python3 bench/lean/lean.py launch "$mailbox" 8 | sed 's/^{/{"build": "B", /'
    APP="$a" python3 bench/lean/lean.py keys "$mailbox" | sed 's/^{/{"build": "A", /'
    APP="$b" python3 bench/lean/lean.py keys "$mailbox" | sed 's/^{/{"build": "B", /'
  done
  i=$((i + 1))
done
