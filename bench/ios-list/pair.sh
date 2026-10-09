#!/bin/sh
# Runs scenarios on two builds in turn and keeps every run, for a before/after table.
#   bench/ios-list/pair.sh <before.app> <after.app> <synth|real> "<scenarios>" <folder to keep the runs in>
# Prints nothing but where the runs went; read them with summary.py, or compare with ab.py.
a="$1"; b="$2"; box="$3"; what="$4"; keep="$5"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$keep/before" "$keep/after"
for name in $what; do
  for side in before after; do
    app="$a"; [ "$side" = after ] && app="$b"
    APP="$app" "$here/run.sh" "$box" "$name" >/dev/null 2>&1 || echo "run failed ($side $name)" >&2
    cp "$here/../../build/run/ios-list-$box-out/$name${PICTURES:+-pictures}.jsonl" "$keep/$side/$box-$name${PICTURES:+-pictures}.jsonl"
  done
done
echo "$keep"
