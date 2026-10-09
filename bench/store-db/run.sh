#!/bin/sh
# Benchmarks for the local database layer (Core/Sources/MachCore/Store.swift). Headless; never touches real mail.
#
#   bench/store-db/run.sh synth|real [tag] [section...]
#
# Sections: read thread search write misc storage observe pages (default: all of them).
# Each section runs on its own fresh throwaway copy of the mailbox. Lines are printed and also kept in
# build/store-db/<mailbox>-<tag>.jsonl (git-ignored; holds numbers and plan text only, never mail).
#
#   bench/store-db/run.sh synth digest       fingerprints of every read's result, for comparing two builds
#   bench/store-db/run.sh synth digest-write fingerprints of every table after a fixed series of writes
set -eu
umask 077
cd "$(dirname "$0")/../.."
mailbox="${1:?synth or real}"
tag="${2:-run}"
[ $# -ge 2 ] && shift 2 || shift 1
[ $# -gt 0 ] || set -- read thread search write misc storage observe pages
(cd Core && swift build -c release --product machbench >/dev/null 2>&1)
mkdir -p build/store-db
chmod 700 build
work="build/store-db/work-$mailbox"
if [ "$tag" = digest ] || [ "$tag" = digest-write ]; then
  bench/data.sh fresh "$mailbox" "$work"
  Core/.build/release/machbench store "$work" "$tag"
  rm -rf "$work"
  exit 0
fi
out="build/store-db/$mailbox-$tag.jsonl"
: > "$out"
for section in "$@"; do
  bench/data.sh fresh "$mailbox" "$work"
  Core/.build/release/machbench store "$work" "$section" | tee -a "$out"
done
rm -rf "$work"
