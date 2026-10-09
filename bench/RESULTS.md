# Results

Ten agents hill-climbed one frontier each; every kept change was then merged and re-measured. "Mine" in the last column
means the coordinator re-ran before and after itself, back to back on the same harness; "agent" means the number is
the frontier agent's own run and was not repeated. Times are medians in milliseconds unless a unit is given.
`synth` is the made-up 50,000-message mailbox, `real` a snapshot of the real one (numbers only).

The Mac was heavily loaded for most of the session, so treat single differences under about 15% as noise. iPhone
numbers are from the simulator, never a device: counts (rows rebuilt, layers drawn, megabytes) are exact, times are not
device times.

## Mac and shared code

| Metric | How | synth before → after | real before → after | Run by |
|---|---|---|---|---|
| Open a 150 KB newsletter, key press to laid out | `bench/thread-open/compare.sh A B synth opens:12` | 41.1 → 16.7 (-59%) | 24.4 → 6.8 | mine (synth), agent (real) |
| Open a 200-message thread, key press to laid out | same | 231 → 48 (-79%) | 23 → 5 (31 messages, app side) | mine (synth), agent (real) |
| App-side work to open a 150 KB newsletter | same, `swift_show` | 27.0 → 2.7 (-90%) | 19.6 → 1.9 | mine (synth), agent (real) |
| Second draw after marking read, 150 KB newsletter | `run.sh synth unread` | 157 KB resent → 0.8 KB; page 12 → 1 | same shape | agent |
| Hold j, 3,000 rows, per key until idle | `bench/mac-ui/run.py cursor --against A` | 8.0 → 2.3 (-71%) | 6.2 → 4.3 | mine (synth), agent (real) |
| Hold k, 3,000 rows | same | 8.0 → 2.4 (-71%) | 7.4 → 2.9 | mine (synth), agent (real) |
| Main thread blocked per letter typed in search | `run.py search --against A` | 75.8 → 0.7 (-99%) | 16.9 → 7.3 | mine (synth), agent (real) |
| Undo of 50, until idle | `run.py actions --against A` | 147 → 42 (-71%) | 327 → 65 | mine (synth), agent (real) |
| Star, until idle | same | 13.9 → 6.3 (-55%) | 19.3 → 8.6 | mine (synth), agent (real) |
| Mark Done, until idle | same | 32.2 → 20.4 (-37%) | 39.5 → 33.6 | mine (synth), agent (real) |
| Launch to first list frame | `run.py launch --against A --runs 8` | 525 → 487 (-7%) | 440 → 402 (-9%) | mine |
| Search a word, 50,000 messages | `bench/store-db/ab.sh synth search` | 14.0 → 2.0 (-86%) | 0.60 → 0.29 (-52%) | mine |
| Search a very common word | same | 37.5 → 4.5 (-88%) | 2.9 → 0.65 (-78%) | mine |
| Type a word letter by letter (sum) | same | 222 → 88 (-60%) | 10.3 → 5.3 (-48%) | mine |
| 1-3 letter prefix search | same | 60 → 27 (-55%) | 5.3 → 2.4 (-55%) | mine |
| Mark one thread read (database) | `ab.sh synth write` | 0.82 → 0.07 (-91%) | 0.47 → 0.13 (-73%) | mine |
| Archive 50 threads (database) | same | 50.3 → 13.7 (-73%) | 27.7 → 11.5 (-58%) | mine |
| Mark read while sync is storing mail | same | 62.2 → 13.9 (-78%) | 53.0 → 14.1 (-73%) | mine |
| Store 100 new messages | same | 300 → 148 (-51%) | 301 → 127 (-58%) | mine |
| 100 label changes from Gmail | same | 109 → 22 (-80%) | 80 → 27 (-66%) | mine |
| Inbox read, one account, 600 rows | `ab.sh synth read` | 2.30 → 0.51 | 3.72 → 0.80 (-79%) | agent (synth), mine (real) |
| All Inboxes read, 3,000 rows | same | 35.5 → 4.8 | 4.57 → 1.27 (-72%) | agent (synth), mine (real) |
| First 35 conversations on a first sync (fake Gmail, 120 ms a request) | `bench/sync/run.sh synth first50` | 3.89 s → 0.54 s (-86%) | 3.87 s → 0.50 s | mine (synth), agent (real) |
| First 50 conversations on a first sync | same | 17.2 s → 10.4 s (-40%) | 17.2 s → 10.4 s | mine (synth), agent (real) |
| Processor per idle check, 2 accounts | `run.sh synth poll` | 60.5 → 0.55 (-99%) | 2.13 → 0.88 | mine (synth), agent (real) |
| Decode one downloaded message plus search text | `run.sh synth cpu` | 0.606 → 0.134 (-78%) | 0.150 → 0.051 | mine (synth), agent (real) |
| New-mail signal to on screen, 1 message | `run.sh synth signal` | 249 → 249 (two round trips: already the floor) | 246 → 245 | agent |
| ⌘Enter, main thread held | `bench/lean/lean.py compose` | 21-68 → 0.07 | 180 → 0.06 | agent |
| Draft save while the database is busy, main thread held | same | 152 → 0.015 | — | agent |
| Mac app size | `bench/lean/size.sh build mac` | 8.77 MB → 4.55 MB (-48%) | — | mine |
| Relay: KV reads per mail (one phone, hub awake) | `cd Relay && bun test/bench.js` | 4 → 0 | — | agent (not deployed) |

## iPhone (simulator)

| Metric | How | synth before → after | Run by |
|---|---|---|---|
| Rows rebuilt when one row is ticked | `bench/ios-list/pair.sh A B synth invalidate` | 11 → 1; layers redrawn 58 → 9 | mine |
| Rows rebuilt when a swipe begins | same | 10 → 0; layers redrawn 61 → 0 | mine |
| Swipe let go, row leaves | same | rows 14 → 1; layers redrawn 184 → 56 | mine |
| Layers redrawn opening a conversation | same | 66 → 3 | mine |
| Layers redrawn on back-swipe release | same | 84 → 3 | mine |
| Layers redrawn when a star arrives from the database | same | 61 → 6 | mine |
| Main-thread time: tick / swipe begin / open / back release | same | 23.9 → 11.5 / 9.5 → 2.7 / 24.4 → 13.9 / 33.4 → 13.5 | mine (simulator time) |
| New mail while scrolled down moves the row on screen | `pair.sh ... jump` | 78 pt on 9 of 9 → 0 pt on 6 of 9 | agent |
| Whole-screen rebuilds per letter typed (compose, search) / per toast | `bench/ios-rest/run.sh synth compose` | 1 → 0 / 1 → 0 | agent |
| Wide newsletter overflowing the screen on first frame | `bench/ios-thread/run.sh synth fit,opens:8` | 252 pt → 1 pt (costs ~12 ms more layout on a 150 KB newsletter) | agent |
| App memory after scrolling 1,000 rows (1,060 pictures) | `PICTURES=1 bench/ios-rest/run.sh synth memory` | 50.3 → 41.8 MB | agent |
| App memory after 20 conversations | same | 58.6 → 48.3 MB | agent |
| Our start-up code before the first frame | `bench/ios-launch/locked.sh ab A B synth 15` | 45.7 → 34.1 (-25%) | agent |
| Banner held when the picture server never answers | `locked.sh notify 6` | 8.7-21 s → 3.1 s | agent |
| iPhone app size (device build) | `bench/lean/size.sh build ios` | 9.2 MB → 4.5 MB | agent |

Everything in the first table that is shared code (database, search, sync, opening a conversation, typing in search)
applies to the iPhone as well; it was measured on the Mac.

## Did not improve

- New-mail signal to on screen: already two round trips, the minimum without changing the relay.
- iPhone launch to first frame: the 12 ms saved in our code is inside the noise of the ~195 ms UIKit and SwiftUI spend.
- iPhone scrolling: about 2.3 ms of main thread a row, nearly all SwiftUI layout; a UIKit or Canvas row was not built.
- iPhone keyboard appearing: ~400 ms is the system's own slide.
- Reading view memory: the page's process grows ~2 MB per heavy newsletter opened (22 → 229 MB after 100) and does not
  shrink. Two attempts did not fix it; the cause is not found.
- Background preparing of collapsed messages (added on main during this work): a rewrite gave mixed numbers and was not kept.
- Mac scroll fling, command bar, list switching: unchanged within noise.
- `-Osize`, thin LTO, dead stripping, 4 GB mmap, FTS5 optimize: no gain or a loss; not kept.

## Held back (on branches, not in `perf`)

- `perf-sync` 48010a7: check every 60 s instead of 15 while the live connection is healthy. Owner said keep 15.
- `perf-sync` 732dada: fetch whole conversations during first sync. Unverified against Gmail's real allowance.
- `perf-ios-rest` 1d8ed0e, 4212172, a6dceed, f68fb41: relay registration only on change, wait for network instead of
  retrying, no re-sync on return from inactive, a push syncing only its account. Owner said keep retrying and
  re-syncing; the other two were judged not worth the risk to banners.
