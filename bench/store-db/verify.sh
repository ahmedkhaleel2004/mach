#!/bin/sh
# Proves the store still returns and writes exactly what it did before the optimizations.
#
#   bench/store-db/verify.sh
#
# Compares fingerprints of every read's result (and of every table after a fixed series of writes) on the synth
# mailbox with the ones recorded from the code before any change (digest-synth.txt, digest-write-synth.txt).
# The recorded files belong to the synth master they were made from; after regenerating the master, record them
# again from the baseline commit. For the real mailbox the fingerprints are kept out of git: record them with
#   bench/store-db/run.sh real digest > build/store-db/digest-real-base.txt   (from the baseline build)
# and this script compares against them when they exist.
set -eu
umask 077
cd "$(dirname "$0")/../.."
status=0
bench/store-db/run.sh synth digest | diff -q - bench/store-db/digest-synth.txt >/dev/null && echo "synth reads: identical" || { echo "synth reads: DIFFERENT"; status=1; }
bench/store-db/run.sh synth digest-write | diff -q - bench/store-db/digest-write-synth.txt >/dev/null && echo "synth writes: identical" || { echo "synth writes: DIFFERENT"; status=1; }
if [ -f build/store-db/digest-real-base.txt ]; then
  bench/store-db/run.sh real digest | diff -q - build/store-db/digest-real-base.txt >/dev/null && echo "real reads: identical" || { echo "real reads: DIFFERENT"; status=1; }
  bench/store-db/run.sh real digest-write | diff -q - build/store-db/digest-write-real-base.txt >/dev/null && echo "real writes: identical" || { echo "real writes: DIFFERENT"; status=1; }
fi
exit $status
