#!/bin/sh
# Prepares the two mailboxes benchmarks run against, under build/data (never committed):
#   build/data/synth   a made-up mailbox of 50,000 messages (same every time)
#   build/data/real    a snapshot of the real mailbox, taken with SQLite's online backup (read-only on the source)
# Then `bench/data.sh fresh <name> <target-dir>` makes a throwaway working copy of either one.
set -eu
# The snapshot is real mail: nobody but the owner may read these folders.
umask 077
cd "$(dirname "$0")/.."
root="${MACH_BENCH_DATA:-$PWD/build/data}"
if [ "${1:-}" = fresh ]; then
  rm -rf "$3"; mkdir -p "$3"; chmod 700 "$3"
  cp -c "$root/$2/mail.sqlite" "$3/mail.sqlite" 2>/dev/null || cp "$root/$2/mail.sqlite" "$3/mail.sqlite"
  exit 0
fi
mkdir -p "$root/synth" "$root/real"
chmod 700 "$root" "$root/real"
if [ ! -f "$root/synth/mail.sqlite" ]; then
  (cd Core && swift build -c release --product machbench >/dev/null 2>&1)
  Core/.build/release/machbench generate "$root/synth" 50000
  rm -f "$root/synth/mail.sqlite-wal" "$root/synth/mail.sqlite-shm"
fi
source="$HOME/Library/Application Support/Mach/mail.sqlite"
if [ ! -f "$root/real/mail.sqlite" ] && [ -f "$source" ]; then
  sqlite3 "file:$source?mode=ro" ".backup '$root/real/mail.sqlite'"
fi
ls -la "$root/synth" "$root/real"
