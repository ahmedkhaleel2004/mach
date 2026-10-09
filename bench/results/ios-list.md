# iPhone list frontier: results

Measured in a headless simulator (iPhone 18 Pro, iOS 27.0, device `MachBench-ios-list`) on a Mac whose load
average was between 60 and 470 for most of the session. **Every result claimed here is an exact count** (view
`body` evaluations by type, layers drawn or made, SQL statements on the main thread, points a row moved).
Processor-time columns are printed by the scripts but were not usable at that load and are not claimed.
Everything was run on the made-up mailbox (`synth`). **Nothing was run on the real mailbox**: the simulator was
shared and time ran out; the counts do not depend on the mail, but that is an inference, not a measurement.

## How to run

    bench/ios-list/build-at.sh 2c8317c before        # the commit before any change, with today's scenarios
    bench/ios-list/build-at.sh WORK after
    bench/ios-list/pair.sh build/apps/before.app build/apps/after.app synth "invalidate swipe jump" build/res
    python3 bench/ios-list/compare.py build/res/before build/res/after synth-invalidate
    bench/ios-list/run.sh synth "scroll loadmore switch search memory lab eq"      # one build
    APP=<app> bench/ios-list/shots.sh <folder>;  bench/ios-list/shots.sh diff <a> <b>     # screenshots, byte compare

Scenarios are in `App/iOS/ListBench.swift` (BENCH builds only, started with `MACH_LIST_BENCH`); the row
experiments in `ListLab.swift`; what SwiftUI skips in `ListEqLab.swift`. The scripts take one of the two
simulator locks in `/tmp` per scenario and give it back in a trap.

## Kept

Counts per action, median of 5 rounds, `before > after` (before = 2c8317c, after = 38d1703).

| What happens | CompactRow bodies | AvatarView bodies | PhoneRoot bodies | Layers drawn |
|---|---|---|---|---|
| Tick a row | 11 > 1 | 11 > 0 | 1 > 0 | 58 > 9 |
| Tick a second row / untick | 10 > 1 | 10 > 0 | 1 > 0 | 56 > 7 |
| A swipe begins | 10 > 0 | 10 > 0 | 0 > 0 | 61 > 0 |
| Each frame of a swipe | 1 > 0 | 1 > 0 | 0 > 0 | 5.45 > 5.45 (the strip behind) |
| Swipe let go, row stays | 11 > 0 | 11 > 0 | 0 > 0 | 102 > 47 |
| Swipe let go, row leaves | 14 > 1 | 14 > 1 | 2 > 1 | 123 > 62 |
| A star arrives from the database | 1 > 1 | 1 > 0 | 1 > 0 | 61 > 6 |
| Mark read (toast shown) | 2 > 2 | 2 > 0 | 2 > 1 | 63 > 9 |
| A toast goes, or is replaced | 0 > 0 | 0 > 0 | 1 > 1 | 61 > 0 |
| New mail arrives | 1 > 1 | 1 > 1 | 1 > 0 | 61 > 61 (every row moves down one) |
| Compose closes | 0 > 0 | 0 > 0 | 1 > 1 | 64 > 3 |
| Open a conversation / close it | 0 > 0 | 0 > 0 | 1 > 1 | 66 > 5 / 65 > 5 |
| Back swipe let go | 0 > 0 | 0 > 0 | 1 > 1 | 84 > 23 |
| A letter typed in search | 1.25 > 1.25 | same | 1.25 > 0 | 50.5 > 8.75 |
| Midnight (day changes) | 0 > 10 | 0 > 0 | 0 > 0 | rows were stale before; now rewritten |
| Cursor move, back-swipe frame | 0 | 0 | 0 | unchanged (already right) |

The thin `SwipeRow` wrapper still runs for every visible row (10) on a tick and when a swipe begins or ends: it
is the view that reads "is this row ticked / being swiped". Its content is skipped.

The first few interactions after launch still rebuild every visible row once: SwiftUI only starts comparing a
kind of view after it has seen it a few times (the `eq` scenario shows 3 unskipped rebuilds, then none).

New mail while scrolled down (`jump`; how far the row on screen moved, checked on every frame; commit 8dcc4bb):

| Scrolled down by | before | after |
|---|---|---|
| 12, 60, 250 rows, three deliveries each | 78.3 pt, 9 of 9 | 0 pt, 6 of 9; 78.3 pt on the first delivery after the benchmark itself set the scroll position (3 of 9) |
| at the top | new row comes into view | same |

## Where a row's cost goes (`lab`, one round, machine loaded: the layer counts are exact, the times are rough)

| Row built as | Layers on screen per visible row | Layers made per scrolled row | Layers drawn per scrolled row | CPU per row, rough |
|---|---|---|---|---|
| nothing (the lazy stack alone) | 1.1 | 0 | 0 | 0.6 ms |
| one Text | 4.5 | 1 | 2 | 1.2 to 1.4 ms |
| three Texts | 11.3 | 3 | 6 | 2.2 to 2.5 ms |
| initials circle only | 7.9 | 2 | 2 | 1.5 to 1.7 ms |
| AvatarView only | 7.9 | 2 | 2 | 1.8 ms |
| CompactRow | 30.7 | 8.9 | 12.3 | about 5 ms |
| + background and divider | 37.5 | 10.9 | 12.3 | about 5 ms |
| + offset/opacity/scale, clip, tap, geometry (the real SwipeRow) | 37.5 | 10.9 | 12.3 | 3 to 4.5 ms (inside the noise of the row above) |

So: the swipe wrapping that `main` added costs no layers and nothing measurable; the row's cost is its six
pieces of text and symbols (each drawn twice when it appears) and the picture. The baseline scroll run agrees:
1 body of each row view, 10.9 layers made, 12.4 drawn, 12.6 layout passes per scrolled row, about 400 layers in
the list for 11 visible rows. Loading older rows cost a frame of 18 to 20 ms main-thread time in that run (3 loads).

## Tried, not kept or not finished

- `.equatable()` on the rows by itself (first attempt): did nothing, because `CompactRow` held `@AppStorage`
  (a view with it never compares equal) and `fixCursor` wrote `selected` on every database change (which reruns
  every row). Both had to be fixed first; they are in the kept commits.
- `List` instead of `ScrollView` + `LazyVStack`: rows came out 52.7 pt high instead of 78.3, so not pixel-identical
  as built; not pursued.
- `UICollectionView` with `UIHostingConfiguration`, a pure UIKit cell, a `Canvas` row, fixed row height,
  flattening the stacks, row-size picture thumbnails (the phone decodes pictures to 288 px for a 138 px circle and
  the 8 MB cache then holds about 24 of them): built into the lab or planned, **not measured**. The simulator
  was unusable for an hour (four simulators, 6.5 GB of swap) and then rationed.
- Load-more off the main thread (in commit 38d1703): the code is in, but the `loadmore` scenario wrote no lines
  (a harness fault not found in time), so **its effect is not measured**. The baseline number above is the target.
- Scroll timing before/after, switching lists, search per letter (beyond the counts above), memory after 3,000
  rows, the run with pictures: scenarios exist, not run on the final build.
- Real touch latency (finger down to first movement, tap to open): not measurable without a finger. By reading
  the code, the pan recogniser fails in its first callback for a vertical drag, so it adds no wait to scrolling.

## Looks: what the screenshots prove and what they do not

Byte-identical before (2c8317c) and after (8dcc4bb), light mode, default row style, made-up mailbox, 19 of 19:
the list, two rows ticked, a swipe held at 40 and 100 points each way, a toast, the list scrolled, All Mail, the
empty Snoozed list, one account, the list switcher, search results (and the six swipe pictures of the two other
launches, which turned out to show the default swipe design again).

**Not proven by screenshot**: dark mode, row styles 0, 2, 3 and 4, swipe designs 2 and 3, pictures off, real
pictures. The script passes those settings as launch arguments (`-rowStyle 2`), and the pictures taken show the
default style, so the arguments are not taking effect; that fault in `shots.sh` was found in the last minutes and
is not fixed. The row styles matter most here, because the row now gets `rowStyle` and `showAvatars` from the list
instead of reading them itself: by reading the code it is the same value used in the same places, but it has not
been seen. Check the four other row styles by eye before merging.
