# iPhone launch frontier: results

Simulator only (iPhone 18 Pro, device `BlitzBench-ios-launch`), on a Mac other agents were loading (load average 7 to
500). **Simulator numbers are not iPhone numbers.** Times are the main thread's own processor time unless marked
"clock"; A/B figures come from two variants launched in turn in the same minutes. Counts are exact.
"real" is the snapshot of real mail: numbers only.

## How to run

    export BLITZ_BENCH_DATA=<folder with synth/ and real/>
    APP=$(DD=build/dd-ios-launch bench/build.sh ios)
    bench/ios-launch/locked.sh launch synth 15          # or real | empty | wal; takes a simulator lock first
    bench/ios-launch/locked.sh open synth 12            # cold launch straight into a conversation (notification path)
    bench/ios-launch/locked.sh ab <A.app> <B.app> synth 15
    bench/ios-launch/locked.sh resume synth 6
    bench/ios-launch/locked.sh notify 6                 # NOTIFY_SOURCE=<old NotificationService.swift> for "before"
    bench/ios-launch/bench.py sample synth out.txt; DSYM=<Mach.app.dSYM> bench/ios-launch/hot.py out.txt in Mach
    bench/ios-launch/bench.py down                      # shut the simulator down at the end

`bench.py` without the lock does the same when nobody else is using a simulator.

## Where a cold launch goes (baseline; main-thread cpu ms, median)

| Stretch | synth (15) | real (15) | first run, no database (12) | 300 MB write-ahead log left by a crash (8, busier Mac) |
|---|---|---|---|---|
| Open database | 8.7 | 7.8 | 7.0 | 9.1 (clock 17.6) |
| Make the conversation web view | 29.2 | 29.3 | 28.1 | 32.9 |
| Read accounts | 4.3 | about 4 | | |
| Read first list (300 rows) | 1.7 | 1.6 | 0.2 | 2.0 |
| Our start-up code, all | 45.7 | 45.0 | 39.9 | 52.9 |
| Start-up code to first frame (UIKit scene, SwiftUI) | 195.0 | 196.0 | 101.7 | 232.0 |
| **Our code to first frame** | **240.7** | **235.2** | **141.6** | **293.0** |
| Our code to tappable (main thread idle) | 258.1 | 245.7 | 143.1 | 316.1 |
| First frame to web view ready, clock | 582 | 612 | 551 | 690 |
| Before any of our code runs (system loader), clock | about 1,500 | about 1,500 | | |

Counts, every launch measured: rows laid out at the first screen refresh 10; screen refreshes with a window but no
rows 0; times the list was replaced after the first read 0 (the database observation re-delivers the same rows, and
the Observation macro in this toolchain drops an equal value without notifying anyone, so there is nothing to fix).

The 1.5 s before our code is the simulator's loader reading every system library by hand; an iPhone does not do
that, so it says nothing about a phone. The app links 38 libraries, all the system's.

What the first frame's 195 ms is made of (same build, a piece switched off, 10 rounds each, launched in turn):

| Switched off | Start-up code to first frame | Rounds won |
|---|---|---|
| Whole screen replaced by one Text (the floor: UIKit + an empty SwiftUI scene) | 188.7 -> 87.8 (-94.5) | 10/10 |
| The 10 visible rows | 146.0 -> 120.2 (-26.6), and -6.8 after the frame | 10/10 |
| The conversation screen parked off the right edge (web view into the window) | 155.4 -> 132.3 (-18.9) | 9/10 |

So: about 88 ms is the system's floor, about 27 ms is rows (2.7 ms a row), about 19 ms is mounting the parked
conversation screen, and about 50 ms is the rest of the list screen.

## Kept

| Change | Measured how | Before | After | Change |
|---|---|---|---|---|
| Database opens on another thread while UIKit starts (`Bootstrap.prewarm`, called from `MachApp.init`) | `ab`, same build with the change off/on, synth, 15 rounds, main-thread cpu ms | our start-up code 45.7 (open database 8.7, read accounts 4.3) | 34.1 (0.1, 0.3) | -25% of our start-up code, 14/15 rounds; -13.0 ms middle round-by-round difference |
| | our code to first frame, same run | 240.7 | 246.8 median; middle round-by-round difference -16.8 ms, 9/15 rounds | not provable at this level: the 195 ms after our code varies by more than 13 ms |
| Notification extension waits at most 3 s for the sender's picture (behaviour change, own commit) | `notify`: picture server that never answers, one lookup | banner held 8.7 s and 21.1 s | 3.05 s and 3.16 s (4.9 s first push after a cold start) | at least -64% |
| | picture server that answers | picture 6/6, 5 ms | picture 5/5, 4-13 ms | same |

The prewarm A/B on the real mailbox was not run (time); the stretches it removes are the same size there
(open database 7.8).

## Measured and left alone

- **Mounting the conversation screen one run-loop pass after the first frame**: first frame 9 ms sooner
  (153.9 -> 140.7, 8/10 rounds) but tappable not sooner (193.2 -> 196.7) and web view ready the same. It only moves
  the work, and it bends the "web view always in the window" rule. Not kept.
- **Smaller first list read (30 rows, then 300)**: the 300-row read is 1.7 ms. Not worth a second apply.
- **Skipping the second identical list application**: already 0 notifications (count).
- **Relay work on resume off the main thread**: `register` 0.10 ms and opening the live link 0.06 ms of main thread
  (against a relay that is not there, sign-ins in files). Not worth a queue. With the real keychain it is unmeasured.
- **Creating the web view after the first frame**: would bring the first frame about 29 ms nearer and push the
  moment a conversation can be shown back by the time the first frame takes. Not tried: it makes the notification
  path worse.
- **Launch after a crash with a 300 MB write-ahead log**: opening the database 9.1 ms cpu, 17.6 ms clock. Launch does
  not wait on recovery. Healthy.
- **First run (no database)**: 142 ms to the welcome screen. Healthy.
- **Notification open at launch** (synth, 12): conversation painted about 6 ms of main-thread time and about
  120 ms of clock after the web view is ready (clock 1,337 -> 1,455 ms after our code starts). It is waiting for the
  web view's page, nothing else.
- **Resume** (synth, 6): our scene-phase code 0.22 ms cpu; foreground to idle 40 ms of main thread, the system's.

## Not measured

- Silent push: `xcrun simctl push` refuses a push with no visible content, so the wake path cannot be run in a
  simulator. Offline the handler returns at once; the sync it starts is the sync frontier's benchmark.
- Page thrown away and reloaded (`webkill`), `open` on real, launch-screen colour: harness written, not run to the
  end before the time limit. The launch screen is `UILaunchScreen: {}` (system black in dark mode) and the app's
  dark background is #111114: a suspected slight mismatch, pictures are taken by `bench.py shots` but not compared.
- In offline runs the web view compiles a block-everything rule list before loading its page, which the real app
  does not do, so "web view ready" here is later than in real use by an unknown amount.
- Mac launch with the shared `Bootstrap` change: `bench/lean/lean.py launch synth` gave 509 ms settled under load,
  with no same-minute "before" build to compare (lean.md recorded 243 to 275). The Mac's path is unchanged except
  that the service is built inside a `static let`. Needs an A/B on a quiet Mac.

## Needs a real iPhone

- How much of the 13 ms the prewarm takes off the main thread shows up as an earlier first frame (it depends on how
  long UIKit takes to start, which the database open overlaps with).
- Keychain reads on the main thread at launch and on every resume (`relayAccounts`), and
  `registerForRemoteNotifications` / the permission request in `PhoneHost.init`: all skipped offline.
- The extension's true cold start (several seconds in the simulator, almost certainly the simulator).
