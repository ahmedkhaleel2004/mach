# Mac window: launch, list and action latency (frontier `mac-ui`)

Branch `perf-mac-ui`. Numbers are milliseconds of main-thread time, measured inside the benchmark app by the hook in
`App/Mac/BenchHook.swift` and driven by `bench/mac-ui/run.py`. "Before" is the app code at the harness commit (62e1875)
built with the same hook; "after" is the head of this branch. The two builds were run in turn (`--against`), so both saw
the same machine load. Raw summaries: `bench/results/mac-ui/final-synth.json` and `final-real.json` (`against` = before, `now` = after).

## Run it again

    export BLITZ_BENCH_DATA=<folder with the synth and real masters>
    bench/build.sh mac                                   # the build under test
    bench/mac-ui/run.py all --data synth                 # every scenario, one table
    bench/mac-ui/run.py all --data real
    bench/mac-ui/run.py cursor,actions --against <baseline Mach.app> --runs 4     # before/after, in turn
    bench/mac-ui/run.py stress                           # cursor never out of view (a count, not a time)
    bench/mac-ui/run.py shot [--script "j;j;x"]          # a picture of the synth window, to compare builds with cmp
    bench/mac-ui/table.py synth.json real.json           # this table, from two `all --against ... --json` files

Scenarios: `launch`, `relaunch`, `cursor`, `scroll`, `switch`, `tab`, `actions`, `palette`, `search`, `stress`.
To make a baseline app: check out 62e1875's `App/Mac/MacApp.swift`, `App/Shared/AppModel.swift`, `App/Shared/Views.swift`
over the head of this branch (keeping `BenchHook.swift`), run `bench/build.sh mac`, and copy the app aside.

## What is measured

- **Key to frame**: from the key reaching the model to the end of that turn of the run loop, after SwiftUI has updated
  and Core Animation has committed.
- **Until idle** (`busy`): everything the main thread did until it next slept, per key. This is the honest number for
  cursor keys, where work spills into later turns.
- **Launch**: time since the process started (kernel start time). "First list frame" is the end of the first run-loop
  turn in which the window is showing and the list has been laid out; the window is behind others (`open -g`), so this
  is the frame being handed to the window server, not light leaving the screen. "Fresh copy" launches use a new APFS
  clone of the mailbox each time (database pages not in memory; the app binary is). 12 launches each.
- Dropped frames cannot be seen in a covered window. As a stand-in the hook counts key presses that took longer than
  8.3 and 16.7 ms (`over8`, `over16` in the JSON).
- The window is 1180 x 780, All Inboxes, avatars on. Lists of 1,000 and 3,000 rows are All Mail (2,645 rows on real).
- The machine was shared with five other benchmark jobs; load swung from 2 to over 200. Differences under about 15%
  on a single line are noise. The lines marked with large changes held across repeated runs.

## Results

| Metric (ms unless said) | synth before | synth after | change | real before | real after | change |
|---|---:|---:|---:|---:|---:|---:|
| Launch: process start to the model holding rows `launch.model` | 162.3 | 102.3 | -37% | 168.9 | 88.2 | -48% |
| Launch: process start to first list frame handed to the screen (fresh copy of the mailbox) `launch.firstFrame` | 356.0 | 314.9 | -12% | 454.6 | 376.4 | -17% |
| Launch again on the same copy (database in memory) `relaunch.firstFrame` | 375.5 | 318.9 | -15% | 336.5 | 303.0 | -10% |
| j, row already in view: main thread until idle `cursor.inview.j` | 5.6 | 3.9 | -30% | 4.7 | 4.0 | -16% |
| j held down, 300 rows (scrolls a row a press): until idle `cursor.j.300` | 6.7 | 3.2 | -52% | 6.4 | 3.8 | -40% |
| j held down, 1,000 rows: until idle `cursor.j.1000` | 7.9 | 3.1 | -61% | 6.5 | 2.6 | -60% |
| j held down, 3,000 rows: until idle `cursor.j.3000` | 8.3 | 3.0 | -64% | 6.2 | 4.3 | -32% |
| k held down, 3,000 rows: until idle `cursor.k.3000` | 10.0 | 2.9 | -71% | 7.4 | 2.9 | -60% |
| j held down from row 1,400 of 3,000: until idle `cursor.j.3000deep` | 7.2 | 3.0 | -59% | 7.0 | 2.4 | -66% |
| Page Down (20 rows), 3,000 rows: until idle `cursor.page.3000` | 30.2 | 22.0 | -27% | 29.9 | 24.4 | -18% |
| Scrolling the list, per frame (mix of 10 rows and 1 row a frame): until idle `scroll.frame` | 7.8 | 7.7 | -1% | 8.8 | 9.3 | +5% |
| g a (All Mail): key to first frame `switch.go.all` | 23.7 | 8.9 | -63% | 60.1 | 54.0 | -10% |
| g t (Sent): key to first frame `switch.go.sent` | 38.4 | 36.2 | -6% | 49.3 | 44.8 | -9% |
| g i (Inbox): key to first frame `switch.go.inbox` | 58.7 | 47.0 | -20% | 57.5 | 54.7 | -5% |
| Ctrl 1 (one account): key to first frame `switch.account.one` | 27.8 | 24.7 | -11% | 31.5 | 26.8 | -15% |
| Ctrl 0 (All Inboxes): key to first frame `switch.account.all` | 46.8 | 43.1 | -8% | 39.5 | 35.9 | -9% |
| Tab (split inbox halves): key to first frame `switch.tab` | 52.5 | 51.4 | -2% | 40.2 | 38.6 | -4% |
| e (Mark Done): key to row gone and cursor moved `act.done` | 18.6 | 16.2 | -13% | 16.1 | 16.6 | +3% |
| e: main thread until idle, database echo included `act.done` | 41.8 | 34.7 | -17% | 39.5 | 33.6 | -15% |
| e with a conversation open (next one shown): key to frame `act.done.open` | 19.7 | 18.4 | -6% | – | – | – |
| e with 50 rows ticked: key to frame `act.done50` | 38.7 | 28.6 | -26% | 37.7 | 28.4 | -25% |
| s (star): key to frame `act.star` | 13.4 | 7.2 | -46% | 8.8 | 5.4 | -39% |
| s: until idle `act.star` | 25.1 | 11.6 | -54% | 19.3 | 8.6 | -56% |
| Shift U: key to frame `act.unread` | 2.7 | 2.1 | -22% | 2.1 | 1.4 | -33% |
| z (undo one): until idle `act.undo` | 21.9 | 21.7 | -1% | 28.2 | 24.6 | -13% |
| z (undo 50): until idle `act.undo50` | 299.1 | 45.2 | -85% | 327.0 | 64.9 | -80% |
| z (undo 50): times the list was set again `act.undo50` | 50.0 | 2.0 | -96% | 39.0 | 2.0 | -95% |
| A write to mail that is not in the list: main thread per write `churn.write` | 0.4 | 0.4 | +7% | 2.1 | 1.9 | -7% |
| Cmd K: key to frame `palette.open` | 17.6 | 17.2 | -2% | 14.3 | 15.9 | +12% |
| Command bar, per typed letter `palette.keystroke` | 1.1 | 1.0 | -12% | 1.6 | 1.5 | -10% |
| Search, main thread per typed letter `search.keystroke` | 118.5 | 2.1 | -98% | 16.9 | 7.3 | -57% |
| Search, first letter to results for the whole text (letters a few ms apart) `search.shown` | 2146.9 | 1182.5 | -45% | 245.4 | 161.6 | -34% |

Other counts:
- Cursor check (`stress`, 360 random bursts of cursor keys, synth): the row under the cursor ended out of view 7 to 10
  times before (SwiftUI's `scrollTo` loses a move when several land in one frame), 0 times after.
- A database write to mail that is not in the list re-delivered the list 20 times out of 20 both before and after; after,
  all 20 are recognised as unchanged and nothing is set (the remaining cost is the unread count).
- Launch breakdown after (synth, median of 12): app delegate starts 89 ms, database open 94, model holding rows 102,
  `applicationDidFinishLaunching` 290, first list frame 315, web view made 359. Before: 89, 95, 162, 328, 356 (web view
  made at about 150, inside the model). About 190 ms between the model and the first frame is AppKit and SwiftUI
  building the window; none of it is ours.
- Window screenshots on synth are byte-identical before and after over 11 key sequences (cursor at both edges, page
  keys, end of list, star, tick, Done and undo, command bar, search). The only differences ever seen were one row's
  hover tint, which follows the mouse.
- Core tests: 23 pass. Mac and iPhone schemes build with no new warnings.

## What changed (one commit each)

1. Cursor move redraws two rows: the list is its own view, rows watch the cursor themselves and are compared before redraw.
2. Cursor kept in view by moving the list's scroll view directly, and not at all when the row already shows.
3. Rows are set only when they changed; undo writes once per kind of change; sets instead of nested scans in actions.
4. Opening a list reads 80 rows before the first frame; the rest arrives off the main thread (a key press completes it first).
5. Search runs off the main thread; typing never waits for it.
6. The conversation web view is made right after the first frame instead of before it.

## Tried, did not help or not kept

- Skipping `scrollTo` using SwiftUI's `onScrollGeometryChange` to know what is visible: the reported rectangle lags a
  scroll by a frame, and the cursor could be left out of view. Replaced by reading the scroll view itself (change 2).
- Watching the cursor from the list's own body (`onChange` on the scroll view): the list body then runs on every move
  and costs about 2.5 ms more than watching from outside it.
- Watching the cursor from a small background view with SwiftUI's `onChange`: cheap, but it drops the last move when
  several land in one frame, exactly as the original did. Replaced by the scroller's own observation.
- Scrolling (fling) per frame: unchanged (7.8 vs 7.7 ms). Not improved by anything here.
- Command bar: opening and typing unchanged; `commands` being rebuilt on each access costs about 1 ms a letter and was left alone.
- Switching lists other than All Mail improved little: after change 4 the time is SwiftUI laying out a screen of new
  rows (`LazyVStack` measuring, text layout, hover hit-testing), not the database.

## Trade-offs to know about

- The web view is warm about 0.2 to 0.35 s later than before. A conversation opened in the first half-second after
  launch waits for the page to load.
- With a search that is slower than typing, results on screen can be for a few letters ago until the search for the
  latest text finishes (before, each letter froze the window until its results came). Arrow keys and Enter wait for it.
- For about 20 ms after opening a list it holds 80 rows, then all of them. A key press in that time reads the rest first.
- The benchmark runs opened 27 to 36 conversations on the real mailbox copy before the rule against it; none since,
  and the driver now never opens one on `real`.
