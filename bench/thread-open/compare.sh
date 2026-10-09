#!/bin/sh
# Runs the same scenario on two builds, one straight after the other (this Mac's load changes from minute to minute,
# so numbers taken far apart cannot be compared), and prints both tables.
#
#   bench/thread-open/compare.sh build/apps/base.app build/apps/new.app synth opens:15
#   bench/thread-open/keep.sh <name>     saves the current build as build/apps/<name>.app
set -eu
umask 077
cd "$(dirname "$0")/../.."
mkdir -p build/results
for app in "$1" "$2"; do
  name="$(basename "$app" .app)"
  case "$app" in /*) path="$app" ;; *) path="$PWD/$app" ;; esac
  out="build/results/$name-$3-$(echo "$4" | tr ':' '-').md"
  APP="$path" bench/thread-open/run.sh "$3" "$4" > "$out"
  echo "== $name ($out)"
  cat "$out"
done
