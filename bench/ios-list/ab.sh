#!/bin/sh
# Compares two builds fairly on a busy machine: runs one scenario on each in turn, several rounds, and prints
# each round's numbers side by side so a difference can be told from noise.
#   bench/ios-list/ab.sh <A.app> <B.app> <synth|real> <scenario> [rounds] [metric[:field] ...]
#   bench/ios-list/ab.sh build/apps/before.app build/apps/after.app synth scroll 4 scroll.down2 scroll.down2:layersMade
a="$1"; b="$2"; box="$3"; what="$4"; rounds="${5:-3}"
shift 5 2>/dev/null || shift $#
here="$(cd "$(dirname "$0")" && pwd)"
keep="$here/../../build/run/ab-ios-list-$$"
mkdir -p "$keep"
i=0
while [ "$i" -lt "$rounds" ]; do
  for side in A B; do
    app="$a"; [ "$side" = B ] && app="$b"
    APP="$app" "$here/run.sh" "$box" "$what" >/dev/null 2>&1 || echo "run failed ($side $i)" >&2
    cp "$here/../../build/run/ios-list-$box-out/$what${PICTURES:+-pictures}.jsonl" "$keep/$side-$i.jsonl"
  done
  i=$((i + 1))
done
/usr/bin/python3 "$here/ab.py" "$keep" "$@"
