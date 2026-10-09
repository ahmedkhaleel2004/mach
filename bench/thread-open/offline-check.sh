#!/bin/sh
# Proves that an offline run makes no network requests when a conversation is opened.
#
# The newest inbox conversation of a throwaway synth copy gets pictures, a style sheet, a font, backgrounds and
# media that all point at 127.0.0.1:18473 (this Mac; nothing leaves it). The benchmark app, started with
# BLITZ_OFFLINE=1, listens on that port and counts connections: first from a plain web view given the same HTML
# (the control: it must connect, or a count of zero would mean nothing), then from the real conversation view
# with the conversation opened and every message expanded (which must make none).
#
#   bench/thread-open/offline-check.sh              builds the app; passes only if control > 0 and page = 0
#   APP=<path to Mach.app> bench/thread-open/offline-check.sh
set -eu
umask 077
cd "$(dirname "$0")/../.."
export BLITZ_BENCH_DATA="${BLITZ_BENCH_DATA:-$PWD/build/data}"
app="${APP:-$(DD=build/dd-mac bench/build.sh mac)}"
dir="$PWD/build/run/offline-check"
channel=app.blitzbench.thread-open-offline
bench/data.sh fresh synth "$dir"
base="http://127.0.0.1:18473"
probes="<img src=\"$base/picture.gif\"><img srcset=\"$base/srcset.gif 2x\"><link rel=\"stylesheet\" href=\"$base/sheet.css\"><style>@import url($base/import.css); @font-face { font-family: probe; src: url($base/font.woff); } p { font-family: probe; background: url($base/background.gif); }</style><p style=\"background-image:url($base/inline.gif)\">probe</p><video src=\"$base/video.mp4\" autoplay></video><audio src=\"$base/audio.mp3\" autoplay></audio>"
sqlite3 "$dir/mail.sqlite" "update message set bodyHTML = '$probes' || coalesce(bodyHTML, '') where (accountId, threadId) in (select accountId, threadId from thread_label where labelId = 'INBOX' order by sortDate desc limit 1)"
before="$(pgrep -f "$app/Contents/MacOS/Mach" || true)"
open -g -n "$app" --env BLITZ_DATA_DIR="$dir" --env BLITZ_OFFLINE=1 --env BLITZ_DEBUG_CHANNEL="$channel"
pid=""
for _ in $(seq 100); do
  pid="$(pgrep -f "$app/Contents/MacOS/Mach" | grep -v -x -F "${before:-none}" | tail -1 || true)"
  [ -n "$pid" ] && grep -q thread_web_ready "$dir/bench.jsonl" 2>/dev/null && break
  sleep 0.2
done
[ -n "$pid" ] || { echo "the benchmark app did not start"; exit 1; }
trap 'kill "$pid" 2>/dev/null || true' EXIT
sleep 1.5
swift bench/thread-open/send.swift "$channel" "bench:offline"
for _ in $(seq 60); do
  grep -q 'thread_offline_check\|thread_bench_error' "$dir/bench.jsonl" && break
  sleep 0.5
done
kill "$pid" 2>/dev/null || true
trap - EXIT
grep 'thread_offline_check\|thread_bench_error' "$dir/bench.jsonl" || echo "no result"
grep -q '"control":[1-9]' "$dir/bench.jsonl" && grep -q '"page":0[,}]' "$dir/bench.jsonl"
