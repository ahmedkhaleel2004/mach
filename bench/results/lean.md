# lean: build size, Mac memory and idle, compose, the push relay

Measured on 2026-10-08 on the owner's Mac (10 cores, 16 GB) while five other agents were building and benchmarking
on it, so every time below carries real noise: the same launch measured 265-375 ms depending on the minute. Sizes,
counts of calls and counts of rebuilt views are exact. `synth` is the 50,000-message made-up mailbox, `real` the
snapshot of the real one (numbers only). Set `export MACH_BENCH_DATA=<folder with synth/ and real/>` first; the Mac
benchmarks need `bench/build.sh mac`.

## Kept

| Metric | How (exact command) | Baseline | Final | Change |
|---|---|---|---|---|
| Mac app, whole bundle | `bench/lean/size.sh build mac` (`bundle_bytes`) | 8,798,659 B | 4,411,555 B | -49.9% |
| Mac executable | same (`executable_bytes`) | 8,490,344 B | 4,103,240 B | -51.7% |
| Mac symbol table inside the app | same (`linkedit_bytes`, `symbols`) | 4,898,816 B, 33,931 | 524,288 B, 2,211 | -89% |
| iPhone app (device build), whole bundle | `bench/lean/size.sh build ios` | 9,217,167 B | 4,543,919 B | -50.7% |
| iPhone executable | same | 8,755,808 B | 4,142,536 B | -52.7% |
| iPhone notification extension | same (`notify_extension_bytes`) | 177,669 B | 117,693 B | -33.8% |
| Made-up-mailbox generator inside the shipping app | same (`bench_code_strings`; code size from `size -m`) | present (1 string, about 11 KB of code) | absent (0) | gone |
| ⌘Enter: main thread held (reply to a 147 KB / 398 KB message) | `bench/lean/lean.py compose synth` / `real` (`compose.send`, `call_ms`) | synth 21-68 ms, real 180-183 ms | synth 0.07 ms, real 0.05-0.06 ms | -99.9% |
| ⌘Enter to compose view gone | same (`compose.send`, `ms`) | synth 90-127 ms, real 350-377 ms | synth 3-5 ms, real 5 ms | -96% / -99% |
| Save after a pause in typing, while the database is busy writing for 200 ms: main thread held | same (`compose.save_while_db_busy`) | synth 152 ms, real 152 ms | synth 0.014 ms, real 0.016 ms | -99.99% |
| Views rebuilt per character typed | same (`compose.type_char`, `bodies_*`) | MainView 1 + ComposeView 1 | ComposeView 1 | window behind no longer rebuilt |
| App memory with a picture for every sender, after 500 j presses | `bench/lean/lean.py avatars synth` | 76.6 MB | 60.5 MB | -21% |
| Same, after 1000 j presses | same | 94.2 MB | 67.3 MB | -29% |
| Relay, 1 mail 1 phone, hub awake: store reads / hub calls | `cd Relay && bun test/bench.js` (old relay: `bun test/bench.js <old worker.js>`) | 4 / 2 | 0 / 1 | -100% / -50% |
| Relay, 1 mail 1 phone, hub asleep: store reads in a row / Apple token signings | same | 4 / 1 | 2 (3 reads, two side by side) / 0 | |
| Relay, repeated notification: store reads / Gmail calls | same | 2 / 1 | 0 / 0 | -100% |
| Relay, 5 mails 2 phones: store reads; simulated time to all pushed | same | 12; 1761 ms | 0; 711 ms | -100%; -60% |
| Relay, 1 mail 3 phones: simulated time to all pushed | same | 567 ms | 346 ms | -39% |
| Relay, first mail of the day: simulated time to first push | same | 912 ms | 461 ms | -49% |
| Relay: hub wake-ups from app pings | read of the code; `bun test/smoke.js` checks the answer | 1 per app every 25 s | 0 | |

The relay times are a simulation with a fixed made-up delay per outside call (store 8 ms, Gmail 120 ms, Google
150 ms, Apple 90 ms): they show how many calls sit in a row, not what Cloudflare would measure. The relay changes
are NOT deployed; see "Needs the owner".

## Measured, no change wanted or found

| Metric | How | Baseline | Final |
|---|---|---|---|
| Launch to first settled screen, synth / real (median of 10) | `bench/lean/lean.py launch synth` / `real` | 275 / 265 ms (p90 376 / 354) | 243 / 253 ms (p90 261 / 267); the Mac was quieter, see next row |
| Same, stripped build against unstripped, taking turns | `bench/lean/ab.sh <A.app> <B.app>` | 361-365 / 362-374 ms | 356-360 / 345-366 ms: no difference beyond noise |
| j key to settled screen, synth / real | `bench/lean/lean.py keys synth` / `real` | 7.3-7.9 / 6.6-7.7 ms | 6.4-6.5 / 7.5-8.1 ms: noise |
| Typing one character (time to settled screen), new message | `lean.py compose` (`compose.type_char`) | 0.75-1.4 / 0.73-1.6 ms | 0.76 / 0.70-0.77 ms: noise; a profile shows it is the text box's own layout |
| `c` to compose view on screen | `lean.py compose` (`compose.open`) | 9.9-10.3 / 10.6-10.9 ms | 9.6-10.6 / 9.5-10.5 ms |
| `r` on a 200-message, 1.36 MB conversation with nothing open: the call | `lean.py compose synth` (`compose.reply_start_call`) | 1.6-2.2 ms | 1.4 ms |
| Building the quoted reply for a 150 KB / 407 KB message | `bench/lean/core.sh` (`compose.build_reply`) | 0.027 / 0.128 ms | same |
| Draft save, database not busy, 149 KB / 404 KB quote | `bench/lean/core.sh` (`compose.save_draft`) | 0.08 / 0.18 ms | same (now off the main thread) |
| Address lookup per keystroke, on the main thread (2,133 / 681 contacts) | `lean.py compose` (`compose.contacts_lookup`) | 0.27 / 0.12 ms (max 0.6) | unchanged, left as it is (see below) |
| Name to send under, both accounts | `bench/lean/core.sh` (`compose.sender_name`) | 0.02 / 3-9 ms | same (now off the main thread) |
| Putting a 150 KB / 407 KB reply in the outbox | `bench/lean/core.sh` (`compose.queue_send`) | 8-17 / 11-25 ms | same (now off the main thread) |
| App memory, just launched | `bench/lean/lean.py memory synth` / `real` | 47.4 / 49.2 MB | 47.8 / 50.2 MB |
| App memory, after 60 s idle | same | 47.5 / 63.4 MB | 62.4 / 63.6 MB (the 14 MB step is macOS photographing the window; it comes when it likes) |
| App memory, after 500 j presses | same | 50.9 / 69.1 MB | 67.0 / 68.3 MB |
| App memory, after opening 30 conversations (synth only in the final run) | same | 54.5 / 73.3 MB | 72.6 MB / not run |
| App memory, after switching lists 20 times | same | 64.2 / 79.9 MB | 64.4 / 74.6 MB |
| Web helpers (content + GPU + network), launched | same | 46 / 43 MB | 57 / 43 MB |
| Web helpers after opening 30 conversations, synth | same | 85 MB | 84 MB |
| Idle 5 minutes in the background, app: processor time, wake-ups | `bench/lean/lean.py idle synth` / `real` | 232 ms, 338 wake-ups / 882 ms, 686 wake-ups | 22 ms, 45 wake-ups / 18 ms, 28 wake-ups (nothing I changed runs when idle: the first run shared the Mac with my other benchmarks; treat 20-230 ms per 5 minutes as the range) |
| Our own code running while idle (30 s profile, offline) | `sample <pid> 30` by hand | 0 of about 30,000 main-thread samples; no timer or loop of ours runs offline | 0 |
| Dylibs linked / embedded; static initializers | `bench/lean/size.sh` | 34 / 0; 0 (Mac), 36 / 0; 0 (iPhone) | same |
| Compiler warnings in the project's own code outside ThreadWeb.swift | `bench/build.sh mac`, `bench/build.sh ios` | 0, 0 | 0, 0 |
| Clean / one-file incremental Release build, Mac | `bench/lean/size.sh build mac` timed | 91 s / not measured | 65 s / 8 s (load on the Mac differs between the two) |

Where the app's memory is (real copy, after driving it, 80 MB): 51 MB is malloc, of which only 20-24 MB is live
objects (`heap`: almost all SwiftUI, AppKit and CoreFoundation internals; our 300 list rows are well under 1 MB) and
the rest is freed memory the allocator holds on to; 14 MB of that is one block macOS used to photograph the window
for "Resume" (found with `malloc_history`: `NSPersistentUIWindowSnapshotter`). CoreAnimation is 8.5 MB. The database
does not count: its 256 MB map shows as 9-12 MB of clean file pages that cost nothing, and SQLite's own page cache
is 2.3 MB. Sender pictures: 57 files, 284 KB, at most 4 MB decoded on this mailbox.

## Tried, did not help or not kept

- `DEAD_CODE_STRIPPING=YES`: -12 KB. Swift marks every public function of a package "no dead strip", so the linker
  keeps all of GRDB and MachCore whether called or not. With no exported symbols as well: -213 KB of export table,
  which stripping removes anyway. Dropped.
- `-Osize` for the app target: executable 4,101,032 -> 3,987,176 B (-2.8%). Launch, j key and list switch showed no
  difference, but the noise on this Mac (±20%) is larger than any slowdown it could cause, and 114 KB is not worth
  a risk I cannot measure. Not kept; safe to revisit on a quiet Mac.
- `LLVM_LTO=YES_THIN`: 0 bytes (there is no C code of ours to optimise across).
- `SWIFT_ENFORCE_EXCLUSIVE_ACCESS=compile-time`: 16 bytes; no effect.
- Losslessly shrinking the icon PNGs: the asset compiler re-encodes them into `Assets.car` (253 KB) either way.
- Turning off macOS's window photograph (`isRestorable = false`, and `disableSnapshotRestoration()`): app memory
  58 -> 47-49 MB 40 s after launch, but with it the window did not come back at the size it was left in my test,
  and the test itself was not steady (with photographs kept it came back right once and wrong twice). Not kept.
- Moving the address lookup off the main thread: it costs 0.12-0.27 ms per keystroke (max 0.6 ms). Doing it later
  would let Tab accept a suggestion for what was typed a moment ago. Left synchronous.
- A reply's quoted original: the regex over the whole message is 0.03-0.13 ms, and typing does not get slower with
  a 400 KB quote (checked with a profile). Nothing to fix.

## Idle, by reading the code

Offline (how benchmarks run) nothing of ours repeats: no polling, no relay connection, and `thread.html` has no
timer or animation loop. Online there are three things, none changed here because none can be measured offline:
the sync check (every 15 s in front, 90 s in the background: the sync agent's), the relay connection's "ping" every
25 s, and, with no network at all, a reconnect attempt plus a full sync attempt every 30 s for as long as the
network is away (`LiveLink.retry` in `App/Shared/Live.swift`). The last one is worth changing to wait for the
network to come back (`waitsForConnectivity`, then one sync when the connection opens) the next time someone can
test it against a live relay.

## Needs the owner

- The relay changes take effect only when deployed (`wrangler deploy`), which I did not do. Endpoints, payloads and
  what is stored are unchanged (a stored token gains an expiry note the old relay ignores), so today's apps work
  with the new relay, new apps with the old one, and rolling back is safe.
- Symbols now live in `Mach.app.dSYM` beside the built app instead of inside it. Keep the .dSYM of the build
  you install if you want crash reports with function names. I could not try a signed build (no keychain access);
  this is the same strip step Xcode's Archive runs.
