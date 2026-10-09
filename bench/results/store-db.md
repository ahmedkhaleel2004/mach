# Store / database layer: results

Branch `perf-store-db`. Everything is headless (`blitzbench store`), measured on throwaway copies of the two
mailboxes: `synth` (50,000 made-up messages, 2 accounts, 1.2 GB) and `real` (a snapshot of a real mailbox,
~3,200 messages, 116 MB; numbers only).

## How to re-run

    export BLITZ_BENCH_DATA=<folder holding synth/ and real/>
    bench/store-db/run.sh synth            # every section, prints JSON lines, keeps build/store-db/synth-run.jsonl
    bench/store-db/run.sh real
    bench/store-db/run.sh synth run search write      # only some sections
    bench/store-db/compare.py bench/store-db/baseline-synth.jsonl build/store-db/synth-run.jsonl
    bench/store-db/verify.sh               # results and written tables identical to before the changes
    (cd Core && swift test)                # 28 tests (23 before; 5 new in StorePerfTests.swift)

Sections: `read` (lists), `thread` (one conversation), `search`, `write` (key presses and what sync stores),
`misc` (smaller queries and every query plan), `storage` (open, file, a 3,000-message write burst, WAL),
`observe` (refresh work per unrelated sync write), `pages` (pages a statement reads from a cold file).
`bench/store-db/profile.sh synth list|modify|save|labels|recompute|search` samples one operation in a loop.

This Mac was busy the whole session (load average between 4 and 120), so every number below comes from one
back-to-back run of two binaries on fresh copies: the code before any change (commit b858e70, built with the
final benchmark harness) and the final code. `bench/store-db/ab.sh` does that:

    git archive b858e70 Core | tar -x -C build/basetree      # then copy today's Core/Sources/blitzbench/*.swift and
    (cd build/basetree/Core && swift build -c release)       # StoreBenchSupport.swift over it (plus a one-line
    cp build/basetree/Core/.build/release/blitzbench build/blitzbench-base   # stripReference = strip shim)
    bench/store-db/ab.sh synth read thread search write misc storage observe pages

The raw lines of that run are `bench/store-db/baseline-*.jsonl` and `final-*.jsonl`; `table.py` prints the table.

## What changed, by impact

1. **Archive / star / mark read (`modifyThreads`) and everything sync writes.** Rebuilding a thread deleted its
   list rows with a statement that walked every list row of the account, re-inserted them and re-saved the thread.
   Now: an index by thread (migration `perf-thread-label-by-thread`), and only what differs is written.
   Mark one thread read 0.79 -> 0.07 ms (synth), 0.46 -> 0.12 ms (real). Archive 50: 51.5 -> 14.3 ms, 29.0 -> 11.9 ms.
   100 label changes from Gmail: 115 -> 23 ms, 80 -> 27 ms. 100 already-known messages: 110 -> 17 ms, 66 -> 14 ms.
2. **Lists (`threads`, and the observed list).** Rows are read by position and the stored string lists are cut apart
   by hand instead of going through the generic record decoder; All Inboxes reads only the rows each account
   contributes. One-account inbox of 600: 2.30 -> 0.51 ms (synth), 3.62 -> 0.82 ms (real). All Inboxes, 3,000 rows:
   35.5 -> 4.8 ms, 16.2 -> 4.1 ms.
3. **Search.** From 2,000 matching messages on, search walks threads newest first through two covering indexes
   (new index `thread_recent`, migration `perf-thread-by-date`) instead of looking up the thread of every match and
   sorting them all. A word on 50,000 messages: 15.6 -> 2.5 ms; a very common word 42.8 -> 5.5 ms; 1-3 letter
   prefixes 66-90 -> 28-29 ms; typing a word letter by letter 255 -> 91 ms. Real: 1 letter 5.5 -> 2.5 ms, common word
   3.2 -> 0.66 ms. Cold file: a broad query read 33,463 pages for the join before, about 40 for the walk now.
   Same threads in the same order, ties included.
4. **A key press while sync is storing mail.** The search text of new mail (HTML to plain text, ~85% of storing a
   message) is prepared before the write lock is taken, and that conversion is about 45% faster (three steps by
   hand, compared against the old version over every stored body: 0 differences). Mark-read while sync stores
   batches of 20: 66.7 -> 14.0 ms (synth), 56.9 -> 14.0 ms (real). Storing 100 new messages: 330 -> 197 ms, 254 -> 128 ms.
   A burst of 3,000 new messages: 9.5 -> 4.4 s, 7.8 -> 3.8 s.
5. **Refreshes during sync.** The open conversation, the unread counts and the account list are no longer sent to
   the app again when a re-read finds the same value: for 50 unrelated sync writes, 150 -> 50 refreshes with a list,
   the counts and a conversation observed (the 50 left are the list, see below). CPU spent re-reading an observed
   list per write: 7.7 -> 1.0 ms (600 rows), 36.9 -> 5.2 ms (3,000 rows) on synth.
6. **Small ones.** One message / a short conversation: statement kept prepared (20 single-message threads in a row
   0.87 -> 0.48 ms; one message by id 0.048 -> 0.015 ms). `dueSnoozes` reads the snoozed list's index (1.16 -> 0.017 ms).
   One look at the queue of unsent changes per sync batch instead of one scan per message.

Migrations the real database runs on next launch: two `CREATE INDEX`, 62 ms together on the 116 MB real snapshot
(134 ms on synth), +0.8 MB of file (+2.3 MB on synth). Both were run through `Store.init` on copies of both
mailboxes by every benchmark and by `verify.sh`; an older build opening the migrated file just ignores the indexes.

## Table

Median of 12-200 runs per metric (see the `runs` field in the result files), same-session before/after.
The "extra CPU per write" rows are a difference of two ~5 ms measurements and wobble by about 2 ms on this machine;
the refresh counts next to them are exact.

| metric | synth before | synth after | change | real before | real after | change |
|---|---|---|---|---|---|---|
| read.one.inbox.300 | 1.921 ms | 0.425 ms | -78% | 1.810 ms | 0.442 ms | -76% |
| read.one.inbox.600 | 2.303 ms | 0.513 ms | -78% | 3.616 ms | 0.824 ms | -77% |
| read.one.inbox.3000 | 2.255 ms | 0.530 ms | -76% | 4.612 ms | 0.989 ms | -79% |
| read.one.all.300 | 1.844 ms | 0.430 ms | -77% | 1.754 ms | 0.366 ms | -79% |
| read.one.all.600 | 3.607 ms | 0.797 ms | -78% | 3.431 ms | 0.707 ms | -79% |
| read.one.all.3000 | 17.2 ms | 3.618 ms | -79% | 12.5 ms | 2.716 ms | -78% |
| read.one.done.300 | 1.738 ms | 0.386 ms | -78% | 1.692 ms | 0.386 ms | -77% |
| read.one.done.600 | 3.395 ms | 0.734 ms | -78% | 3.341 ms | 0.728 ms | -78% |
| read.one.done.3000 | 17.1 ms | 3.622 ms | -79% | 6.130 ms | 1.313 ms | -79% |
| read.one.user.300 | 0.404 ms | 0.117 ms | -71% | 0.259 ms | 0.079 ms | -69% |
| read.one.user.600 | 0.394 ms | 0.116 ms | -71% | 0.256 ms | 0.080 ms | -69% |
| read.one.user.3000 | 0.402 ms | 0.116 ms | -71% | 0.257 ms | 0.081 ms | -68% |
| read.one.snoozed.300 | 1.819 ms | 0.413 ms | -77% | 1.765 ms | 0.377 ms | -79% |
| read.one.snoozed.600 | 1.830 ms | 0.400 ms | -78% | 1.756 ms | 0.383 ms | -78% |
| read.one.snoozed.3000 | 1.837 ms | 0.410 ms | -78% | 1.761 ms | 0.374 ms | -79% |
| read.merged.inbox.300 | 3.804 ms | 0.592 ms | -84% | 1.983 ms | 0.574 ms | -71% |
| read.merged.inbox.600 | 4.710 ms | 1.049 ms | -78% | 3.792 ms | 1.028 ms | -73% |
| read.merged.inbox.3000 | 4.712 ms | 1.312 ms | -72% | 5.139 ms | 1.273 ms | -75% |
| read.merged.all.300 | 3.770 ms | 0.609 ms | -84% | 3.766 ms | 0.549 ms | -85% |
| read.merged.all.600 | 7.407 ms | 1.063 ms | -86% | 6.744 ms | 0.949 ms | -86% |
| read.merged.all.3000 | 35.5 ms | 4.783 ms | -87% | 16.2 ms | 4.061 ms | -75% |
| read.merged.done.300 | 3.605 ms | 0.594 ms | -84% | 3.500 ms | 0.526 ms | -85% |
| read.merged.done.600 | 7.141 ms | 1.013 ms | -86% | 5.987 ms | 0.946 ms | -84% |
| read.merged.done.3000 | 35.2 ms | 4.624 ms | -87% | 8.835 ms | 2.298 ms | -74% |
| read.merged.user.300 | 0.610 ms | 0.240 ms | -61% | 0.317 ms | 0.113 ms | -64% |
| read.merged.user.600 | 0.608 ms | 0.237 ms | -61% | 0.318 ms | 0.111 ms | -65% |
| read.merged.user.3000 | 0.666 ms | 0.242 ms | -64% | 0.314 ms | 0.113 ms | -64% |
| read.merged.snoozed.300 | 1.912 ms | 0.497 ms | -74% | 1.808 ms | 0.471 ms | -74% |
| read.merged.snoozed.600 | 1.908 ms | 0.501 ms | -74% | 1.843 ms | 0.459 ms | -75% |
| read.merged.snoozed.3000 | 1.934 ms | 1.031 ms | -47% | 1.846 ms | 0.454 ms | -75% |
| read.rawrows.all.3000 | 2.160 ms | 2.268 ms | +5% | 1.369 ms | 1.310 ms | -4% |
| read.unreadCount | 0.154 ms | 0.150 ms | -3% | 0.234 ms | 0.233 ms | -0% |
| read.thread.one | 0.045 ms | 0.011 ms | -76% | 0.046 ms | 0.011 ms | -76% |
| read.threads.ids50 | 0.290 ms | 0.100 ms | -66% | 0.298 ms | 0.109 ms | -63% |
| thread.newsletter | 0.071 ms | 0.051 ms | -28% | 0.196 ms | 0.178 ms | -9% |
| thread.middle | 0.358 ms | 0.354 ms | -1% | 0.320 ms | 0.304 ms | -5% |
| thread.longest | 1.230 ms | 1.268 ms | +3% | 0.317 ms | 0.303 ms | -4% |
| thread.20singles | 0.869 ms | 0.483 ms | -44% | 0.711 ms | 0.319 ms | -55% |
| thread.lastMessages20 | 0.583 ms | 0.205 ms | -65% | 0.787 ms | 0.402 ms | -49% |
| thread.message.one | 0.048 ms | 0.015 ms | -69% | 0.047 ms | 0.015 ms | -68% |
| search.all.prefix1 | 71.5 ms | 29.2 ms | -59% | 5.476 ms | 2.454 ms | -55% |
| search.all.prefix2 | 90.3 ms | 28.6 ms | -68% | 1.735 ms | 1.179 ms | -32% |
| search.all.prefix3 | 65.7 ms | 28.0 ms | -57% | 1.345 ms | 0.747 ms | -44% |
| search.all.prefix5 | 15.5 ms | 2.297 ms | -85% | 0.621 ms | 0.301 ms | -52% |
| search.all.word | 15.6 ms | 2.525 ms | -84% | 0.625 ms | 0.297 ms | -52% |
| search.all.twowords | 2.697 ms | 3.190 ms | +18% | 0.250 ms | 0.174 ms | -30% |
| search.all.wordprefix | 30.4 ms | 31.2 ms | +3% | 0.782 ms | 0.465 ms | -41% |
| search.all.rare | 27.2 ms | 3.290 ms | -88% | 0.106 ms | 0.082 ms | -23% |
| search.all.common | 42.8 ms | 5.468 ms | -87% | 3.196 ms | 0.656 ms | -79% |
| search.all.none | 0.103 ms | 0.030 ms | -71% | 0.093 ms | 0.017 ms | -82% |
| search.one.prefix1 | 64.0 ms | 28.4 ms | -56% | 5.300 ms | 2.494 ms | -53% |
| search.one.prefix2 | 83.2 ms | 28.3 ms | -66% | 1.813 ms | 1.182 ms | -35% |
| search.one.prefix3 | 67.0 ms | 27.4 ms | -59% | 1.380 ms | 0.751 ms | -46% |
| search.one.prefix5 | 16.2 ms | 2.387 ms | -85% | 0.615 ms | 0.297 ms | -52% |
| search.one.word | 15.6 ms | 2.120 ms | -86% | 0.614 ms | 0.302 ms | -51% |
| search.one.twowords | 2.722 ms | 2.494 ms | -8% | 0.250 ms | 0.176 ms | -30% |
| search.one.wordprefix | 30.3 ms | 26.3 ms | -13% | 0.777 ms | 0.466 ms | -40% |
| search.one.rare | 25.6 ms | 2.841 ms | -89% | 0.106 ms | 0.079 ms | -25% |
| search.one.common | 42.9 ms | 4.495 ms | -90% | 3.097 ms | 0.620 ms | -80% |
| search.one.none | 0.103 ms | 0.029 ms | -72% | 0.088 ms | 0.017 ms | -81% |
| search.typing.word | 255.4 ms | 90.6 ms | -65% | 10.4 ms | 5.556 ms | -46% |
| write.modify.read1 | 0.787 ms | 0.071 ms | -91% | 0.461 ms | 0.123 ms | -73% |
| write.modify.star1 | 0.903 ms | 0.161 ms | -82% | 0.449 ms | 0.137 ms | -69% |
| write.modify.archive1 | 0.883 ms | 0.128 ms | -86% | 0.500 ms | 0.188 ms | -62% |
| write.modify.snooze1 | 0.910 ms | 0.140 ms | -85% | 0.528 ms | 0.228 ms | -57% |
| write.modify.read1.longest | 9.188 ms | 7.296 ms | -21% | 1.306 ms | 0.810 ms | -38% |
| write.modify.archive50 | 51.5 ms | 14.3 ms | -72% | 29.0 ms | 11.9 ms | -59% |
| write.modify.read50 | 51.5 ms | 13.9 ms | -73% | 28.7 ms | 13.4 ms | -53% |
| write.save.new1 | 2.257 ms | 1.083 ms | -52% | 1.462 ms | 1.105 ms | -24% |
| write.save.new20 | 58.4 ms | 29.0 ms | -50% | 49.9 ms | 26.5 ms | -47% |
| write.save.new100 | 329.8 ms | 197.4 ms | -40% | 253.8 ms | 128.2 ms | -50% |
| write.save.known100 | 109.7 ms | 16.9 ms | -85% | 65.9 ms | 14.1 ms | -79% |
| write.labelChanges100 | 115.0 ms | 23.3 ms | -80% | 80.4 ms | 26.9 ms | -67% |
| write.modify.read1.duringSync | 66.7 ms | 14.0 ms | -79% | 56.9 ms | 14.0 ms | -75% |
| write.recompute.100singles | 111.6 ms | 2.103 ms | -98% | 67.7 ms | 1.956 ms | -97% |
| write.recompute.middle | 1.622 ms | 0.429 ms | -74% | 0.921 ms | 0.177 ms | -81% |
| write.recompute.longest | 2.760 ms | 1.238 ms | -55% | 0.915 ms | 0.177 ms | -81% |
| write.strip.200largest | 1246.1 ms | 721.5 ms | -42% | 975.5 ms | 535.7 ms | -45% |
| write.strip.200largest.reference | 1221.7 ms | 1173.2 ms | -4% | 991.2 ms | 993.3 ms | +0% |
| write.saveThread.middle | 2.435 ms | 1.232 ms | -49% | 3.437 ms | 1.055 ms | -69% |
| misc.senderName | 19.0 ms | 18.9 ms | -0% | 2.641 ms | 2.584 ms | -2% |
| misc.messageIds.inbox | 17.0 ms | 24.0 ms | +41% | 0.850 ms | 0.851 ms | +0% |
| misc.messageIds.unread | 19.0 ms | 20.2 ms | +6% | 0.970 ms | 0.935 ms | -4% |
| misc.incompleteThreads | 35.0 ms | 31.3 ms | -11% | 0.536 ms | 0.528 ms | -1% |
| misc.readyOps | 0.388 ms | 0.367 ms | -5% | 0.393 ms | 0.392 ms | -0% |
| misc.nextOpDelay | 0.038 ms | 0.040 ms | +5% | 0.038 ms | 0.039 ms | +3% |
| misc.pendingOpCount | 0.011 ms | 0.011 ms | +0% | 0.010 ms | 0.011 ms | +10% |
| misc.dueSnoozes | 1.159 ms | 0.017 ms | -99% | 0.262 ms | 0.017 ms | -94% |
| misc.nextSnooze | 0.016 ms | 0.017 ms | +6% | 0.017 ms | 0.017 ms | +0% |
| misc.unreadCount | 0.155 ms | 0.157 ms | +1% | 0.231 ms | 0.236 ms | +2% |
| misc.labels | 0.052 ms | 0.051 ms | -2% | 0.063 ms | 0.063 ms | +0% |
| misc.wholeThreads100 | 0.233 ms | 0.243 ms | +4% | 0.111 ms | 0.111 ms | +0% |
| misc.serverMessageIds100 | 0.142 ms | 0.161 ms | +13% | 0.109 ms | 0.110 ms | +1% |
| misc.threadNeedsCompleting | 0.020 ms | 0.021 ms | +5% | 0.019 ms | 0.020 ms | +5% |
| misc.knownMessageIds | 0.370 ms | 0.371 ms | +0% | 0.109 ms | 0.109 ms | +0% |
| misc.notable20 | 0.181 ms | 0.178 ms | -2% | 0.363 ms | 0.362 ms | -0% |
| misc.contacts.1 | 0.268 ms | 0.286 ms | +7% | 0.129 ms | 0.127 ms | -2% |
| misc.contacts.2 | 0.268 ms | 0.279 ms | +4% | 0.126 ms | 0.125 ms | -1% |
| misc.contacts.4 | 0.279 ms | 0.274 ms | -2% | 0.123 ms | 0.126 ms | +2% |
| misc.contacts.nomatch | 0.271 ms | 0.269 ms | -1% | 0.120 ms | 0.121 ms | +1% |
| storage.open | 0.339 ms | 0.332 ms | -2% | 0.339 ms | 0.328 ms | -3% |
| storage.file | 1198.1 MB | 1198.1 MB | +0% | 111.0 MB | 111.0 MB | +0% |
| storage.burst3000 | 9.478 s | 4.423 s | -53% | 7.767 s | 3.804 s | -51% |
| storage.burst3000.wal_peak | 6.617 MB | 6.628 MB | +0% | 6.357 MB | 5.371 MB | -16% |
| observe.inbox600 (refreshes sent to the app per 50 writes) | 50 | 50 | +0% | 50 | 50 | +0% |
| observe.inbox600 (extra CPU per write) | 7.710 ms | 0.952 ms | -88% | 3.918 ms | 2.972 ms | -24% |
| observe.all3000 (refreshes sent to the app per 50 writes) | 50 | 50 | +0% | 50 | 50 | +0% |
| observe.all3000 (extra CPU per write) | 36.9 ms | 5.214 ms | -86% | 18.4 ms | 9.413 ms | -49% |
| observe.unreadCounts (refreshes sent to the app per 50 writes) | 50 | 0 | -100% | 50 | 0 | -100% |
| observe.unreadCounts (extra CPU per write) | 1.629 ms | 1.322 ms | -19% | 0.137 ms | 1.696 ms | +1138% |
| observe.messages.longest (refreshes sent to the app per 50 writes) | 50 | 0 | -100% | 50 | 0 | -100% |
| observe.messages.longest (extra CPU per write) | 1.508 ms | 1.695 ms | +12% | 0.013 ms | 1.556 ms | +11869% |
| observe.messages.newsletter (refreshes sent to the app per 50 writes) | 50 | 0 | -100% | 50 | 0 | -100% |
| observe.messages.newsletter (extra CPU per write) | 0.284 ms | 0.179 ms | -37% | -0.114 ms | 1.713 ms | - |
| observe.app (refreshes sent to the app per 50 writes) | 150 | 50 | -67% | 150 | 50 | -67% |
| observe.app (extra CPU per write) | 9.609 ms | 4.168 ms | -57% | 11.3 ms | 5.552 ms | -51% |
| pages.list.inbox300 | 49 pages | 49 pages | +0% | 85 pages | 85 pages | +0% |
| pages.list.all3000 | 369 pages | 369 pages | +0% | 372 pages | 372 pages | +0% |
| pages.recompute.read.longest | 506 pages | 506 pages | +0% | 97 pages | 97 pages | +0% |
| pages.recompute.read.newsletter | 43 pages | 43 pages | +0% | 108 pages | 108 pages | +0% |
| pages.modify.read.longest | 142 pages | 142 pages | +0% | 26 pages | 26 pages | +0% |
| pages.messages.longest | 504 pages | 504 pages | +0% | 72 pages | 72 pages | +0% |
| pages.messages.newsletter | 7 pages | 7 pages | +0% | 7 pages | 7 pages | +0% |
| pages.messageIds.inbox | 20326 pages | 20326 pages | +0% | 1785 pages | 1785 pages | +0% |
| pages.search.match.prefix2 | 638 pages | 638 pages | +0% | 23 pages | 23 pages | +0% |
| pages.search.join.prefix2 | 33463 pages | 33463 pages | +0% | 620 pages | 620 pages | +0% |
| pages.search.match.word | 79 pages | 79 pages | +0% | 21 pages | 21 pages | +0% |
| pages.search.join.word | 9864 pages | 9864 pages | +0% | 140 pages | 140 pages | +0% |
| pages.search.walk.2000rows | - | 38 pages | - | - | 68 pages | - |

`storage.file` is the file before the benchmark's own writes; with the two new indexes the real file goes from
116.39 MB to 117.15 MB.

## Proof that results did not change

- `bench/store-db/verify.sh`: fingerprints of every public read (lists for 13 labels x 6 limits x each account and
  merged, 10 searches x 2 limits, every thread's messages, contacts, counts, the sync-side queries) and of every
  table after a fixed series of writes, compared with the same from the code before the changes. Identical on
  synth (committed: `digest-synth.txt`, `digest-write-synth.txt`) and on real (fingerprints kept out of git).
- `StorePerfTests`: the hand parser of stored string lists against JSONDecoder; the incremental thread rebuild
  against a rebuild from nothing; search's two ways against each other on a mailbox built to tie (12 dates for
  about 500 threads); the faster HTML-to-text against the old one (fuzzed, and every UTF-16 unit); that the list still
  refreshes after a change that alters nothing while the conversation and counts stay quiet for unrelated writes.
- `blitzbench store <dir> strip-check`: HTML-to-text, new against old, over every stored body: 0 of 50,000 (synth)
  and 0 of 2,849 (real) differ.

## Tried, did not help or not kept

- **Index `thread_label(accountId, threadId)` without the date:** SQLite's planner ignored it and kept walking
  the account (no gain at all) until `sortDate` was added so the index covers the lookup.
- **`mmap_size` 256 MB -> 4 GB:** full-table scans on synth about 2x faster (senderName 22 -> 10 ms), but 1-3 letter
  searches 7-18% slower and nothing changes on real (the file is under 256 MB). Reverted.
- **FTS5 `optimize` (merge the index into one segment):** prefix scan unchanged (43 ms before and after).
- **HTML-to-text with the patterns run in place on one NSMutableString:** 15-30% faster only; replaced by doing
  the three hot steps by hand (45%).
- **Dropping duplicate values for the thread list too:** would cut the remaining 50 refreshes, but the screen
  shows a change before it is stored and relies on the list coming round to correct it, so it was left alone.

## Measured but left for a decision (each makes something else worse)

- **Bodies in their own table.** Every label change rewrites the whole message row, body included (mark a
  200-message thread read: 4-7 ms; a 150 KB newsletter: 38 pages to the WAL), and reading `attachments` walks the
  body's overflow pages (43 pages for one newsletter, see `pages.recompute.read.newsletter`). Prototype in the
  sqlite shell: after `message_body(id, bodyHTML, bodyText)` + `DROP COLUMN`, 2,000 label updates 172 -> 17 ms and
  the message table shrinks 657 -> 147 MB (synth). Cost: a migration that copies every body (0.9 s on real, about
  15 s on synth), the file grows by the size of the bodies until vacuumed (real 111 -> 198 MB with 80 MB free
  inside), every reader of bodies needs a join, and an older build can no longer open the file. Not done.
- **FTS5 prefix index (`prefix='1 2 3'`).** What is left of a 1-3 letter search is FTS5 gathering every word with
  that prefix. Measured alone in the sqlite shell, that match went from 43 ms to 1.7 ms with a prefix index.
  Cost: the search index doubles (synth 178 -> 343 MB, real 5.6 -> 12.7 MB), the index has to be rebuilt once
  (0.55 s on real, 12 s on synth) and inserts get slower. With `detail=none` the index would instead shrink to
  37 MB, but queries containing combining marks (Thai, Hindi) would change from phrase to AND. Not done.
- **`incompleteThreads` and `senderName`** scan every message of the account (31 ms and 19 ms on synth, 0.5 ms and
  2.6 ms on real). `incompleteThreads` runs from sync's backfill loop; its `DISTINCT ... ORDER BY` on a column that
  is not selected makes an exact rewrite hard to prove, so it was left for the sync frontier.
