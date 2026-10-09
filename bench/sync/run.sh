#!/bin/sh
# Sync benchmarks: Gmail is played by an in-memory fake with a fixed delay per request. Nothing reaches the network.
#
#   bench/sync/run.sh [synth|real] [signal|cpu|first50|initial|outbox|poll ...]
#
# With no names it runs all of them (about 4 minutes). Each one runs on its own throwaway copy of the mailbox
# under build/run/, made with bench/data.sh, and prints JSON lines. See bench/results/sync.md for what they mean.
set -eu
umask 077
cd "$(dirname "$0")/../.."
box="${1:-synth}"
[ $# -gt 0 ] && shift
[ $# -eq 0 ] && set -- signal cpu outbox poll first50 initial
(cd Core && swift build -c release --product machbench >/dev/null 2>&1) || { echo "build failed: cd Core && swift build -c release" >&2; exit 1; }
mkdir -p build && chmod 700 build
for name in "$@"; do
  copy="build/run/sync-$box-$name"
  bench/data.sh fresh "$box" "$copy"
  Core/.build/release/machbench "sync-$name" "$copy"
  rm -rf "$copy"
done
