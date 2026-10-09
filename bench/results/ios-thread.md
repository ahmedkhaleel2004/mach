# ios-thread: reading mail on the iPhone

Branch `perf-ios-thread` (from `ef83b29`). iPhone 18 Pro simulator (iOS 27.0), benchmark build (Release + BENCH),
made-up mailbox, 2026-10-09. One fix is kept. Two experiments did not prove themselves and are not in the tree.
Nothing was measured on the copy of real mail: the Mac was shared by four agents (load average 35 to 250) and
the simulator time ran out.

## How it is measured

    bench/ios-thread/run.sh synth                          every scenario (split the list: a run gives up after 9 minutes)
    bench/ios-thread/run.sh synth fit,opens:8              the first frame of each shape, and tap to laid out
    bench/ios-thread/run.sh synth pictures:2,prepare:3,back:6,next:8
    bench/ios-thread/run.sh synth scroll:2,reclaim:3,heavy:2
    bench/ios-thread/keep.sh <name>                        saves the current build as build/apps/<name>.app
    bench/ios-thread/ab.sh A.app B.app synth prepare:4 1   two builds in turn, then side by side
    bench/thread-open/compare.sh A.app B.app synth opens:12    the Mac check (fingerprints, layout time)

`run.sh` boots its own simulator (BlitzBench-ios-thread) once and leaves it booted; it holds one of the two simulator
locks only while the app measures. Shut the simulator down yourself at the end. `blitzbench pictures <dir>` adds three
made-up conversations with real 1200 by 800 JPEGs (`pics-data`, `pics-cid`, `pics-thread`).

Which numbers to trust: megabytes and counts (overflow in points, messages built, views drawn, requests) are exact.
Processor time of the page's process is fairly steady. Wall-clock milliseconds are a simulator on a busy Mac.

## Kept

| metric | how | before | after |
|---|---|---|---|
| sideways overflow of the open message at first layout, wide shapes (news20, news150, images, pics-data, pics-cid) | `run.sh synth fit` (`over_first`) | 252 points | 1 point |
| the same a second later, news20 and news150 (pictures never arrive) | `over_later` | 252 points | 1 point |
| shrink given at first layout | `zoom_first` | none | 0.599 |
| news150 page layout, same interleaved run (load average about 190) | `ab.sh ... fit,opens:6` | 15 ms | 27 ms |
| news150 page process time per open, same run | `web_cpu` | 20.2 ms | 34.4 ms |
| Mac DOM fingerprints, 7 shapes | `compare.sh ... synth opens:12` | | identical |

The fix (722cf03): a message is fitted once it is on the page, before the first frame and before the place to scroll
to is worked out; several are measured together and then shrunk together. It costs the second layout that shrinking
needs. Before, that layout was either paid later, when a picture arrived, or never, and the mail stayed cut off.

## Baseline of everything else (base build, one run each, load average 35 to 90)

| what | figure |
|---|---|
| page process after 50 / 100 of the largest newsletters, then closed | 22 MB idle, 120 MB, 229 MB; 228 MB after closing |
| 200-message thread, collapsed messages built in the background | 386 ms page process time, done 1.6 s after opening, 13 built before the first paint |
| 40 messages with two pictures each, after the background building | 47 MB before, 168 MB after (one run of 3; 54 MB in a later run of 4) |
| back swipe, dragging, per frame | 1.45 ms app main thread (idle frame 0.1), 0.03 ms page process; only the sliding layer draws (30 in 30 frames) |
| back swipe, lift to list | 149 ms, 7 frames |
| archive with a conversation open | 11.8 ms main thread, 7 ms to the next one laid out, list root drawn twice, one row |
| page process killed, to laid out again | 367 ms (60 messages), 698 ms (150 KB newsletter); scroll place and expanded messages are lost |
| scrolling 48 points a frame | 0.9 to 3.2 ms page process time a frame, at most one long frame a pass |
| picture addresses on opening the same conversation again | 0 requests (12 and 80 on the first open) |

## Tried, not kept

- Emptying the messages of a conversation that left the page (so their memory would not wait for the page's script
  to tidy up): after 100 heavy newsletters 202.9 MB without it, 258.9 MB with it. No help; the cause of the roughly
  2 MB a newsletter that never comes back is still not found.
- New background building (nearest the screen first, after the first frame, paused while scrolling, pictures decoded
  ahead only up to 6 megapixels, far messages up to 2 million characters): messages built before the first paint
  13 to 0 and page process time on the picture thread 364 to 214 ms, but 132 to 188 ms on the 60-message thread,
  621 to 679 ms on the 200-message one, no change in time to first paint, and the memory figures moved too much
  between runs to call (54.3 against 43.4 MB after, from 44.8 and 37.5 before). A first version that also slowed the
  far messages to one every 30 ms tripled the 200-message thread's processor time. Not proven, not kept.
- Looking inside the page's process with vmmap at three stops: the run stalled after the first stop and timed out.

## Not done

Real-mailbox numbers, the next-conversation cost in SwiftUI, keeping the scroll place and expanded messages when the
page's process is killed, and the Mac check of the picture and preparing work.
