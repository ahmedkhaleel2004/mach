# thread-open: opening a conversation

Branch `perf-thread-open`. Mac, benchmark build (Release + BENCH), 2026-10-08. All times are milliseconds,
median with the 90th percentile in brackets, 20 opens per shape after 2 warm-up rounds.

## How it is measured

    bench/thread-open/all.sh <label> 20          # builds, runs everything on synth and real, tables in build/results/
    bench/thread-open/run.sh synth all:20        # opens, unread opens, held j, memory (window left where `open -g` put it)
    bench/thread-open/run.sh synth paint:4       # the only one that shows the window: 4 times, under a second each
    bench/thread-open/run.sh real verify         # classifies every message the old way and the new way, counts differences
    bench/thread-open/offline-check.sh           # proves an offline run makes no network request from the page
    bench/thread-open/run-ios.sh synth all:10    # the same in an iPhone simulator of its own (headless)
    bench/thread-open/compare.sh A.app B.app synth opens:12    # two builds straight after each other (keep.sh saves a build)
    python3 bench/thread-open/diff.py before.md after.md       # two saved tables side by side

What the metrics mean:

- `swift_show`: time on the main thread inside `show(_:)`, from the key press to the script being handed to the page
  (database read, building the payload, JSON, the call). The table printed by `run.sh` splits it further.
- `page_laid_out`: key press to the page having built and laid out the conversation, by the page's own clock
  (whole milliseconds). This does not need the window to be visible.
- `page_painted` (`paint` runs only): key press to two animation frames after layout, with the window brought forward
  without activating the app. It includes waiting for the display's frames, so it cannot go much under 16.
- `later_bytes`, `later_page_ms`: what was sent to the page, and how long the page worked, when the conversation was
  drawn a second time because marking it read came back from the database (unread opens only).
- held j: 30 presses of `j` with a conversation open, 33 ms apart (the keyboard's repeat rate) and back to back.
  `ms` is the last press to its conversation laid out, `press_median` the main-thread time of one press, `lag_max`
  the worst press-to-laid-out among the conversations the page drew.
- memory: megabytes charged to the web content process after opening the 50 largest newsletters, round after round.

Shapes are chosen by size and count only (`pick.sql`): `news20` and `news150` one-message newsletters of about 20 and
150 KB, `plain1` a short one-message mail, `thread60`/`thread200` the conversations nearest 60 and 200 messages
(the real snapshot's longest has 31, so both rows are that one there), `heaviest` the most bytes (synth: 200 messages,
1.6 MB; real: one message, 430 KB).

Honest limits:

- This Mac was busy with five other agents' builds, so numbers taken minutes apart wander by 20 to 50%. Every kept
  change was also checked with `compare.sh` (the two builds one straight after the other); those paired numbers are
  in the commit messages. The baseline and final columns below are two separate full runs.
- Remote pictures are never fetched in a benchmark (first by a rule the benchmark installed before its first open,
  now by the web view itself when offline), so picture download and decoding are excluded from every number, on synth
  and on real. On real mail in daily use, pictures arriving are extra work that is not measured here.
- Real conversations opened by the benchmark with no block at all: 0. Roughly 800 to 1,400 opens of about 100 distinct
  real conversations were made under the benchmark's own rule before the offline commit (dcc5ffe).
- The iPhone simulator was only measured on the final build (the baseline has no way to start the benchmark there).

## Baseline and final

### synth mailbox (50,000 made-up messages)

| scenario | shape | metric | baseline | final | change |
|---|---|---|---|---|---|
| read open | news20 | swift_show | 4.25 (7.12) | 0.97 (1.25) | -77% |
| read open | news20 | page_laid_out | 6.51 (9.60) | 4.61 (5.77) | -29% |
| read open | news150 | swift_show | 19.83 (28.89) | 2.15 (2.54) | -89% |
| read open | news150 | page_laid_out | 31.66 (43.23) | 13.97 (20.84) | -56% |
| read open | plain1 | swift_show | 0.74 (1.21) | 0.72 (0.91) | -3% |
| read open | plain1 | page_laid_out | 1.21 (2.08) | 1.66 (2.67) | +37% |
| read open | thread60 | swift_show | 60.02 (63.47) | 6.83 (9.27) | -89% |
| read open | thread60 | page_laid_out | 69.45 (73.66) | 15.87 (23.78) | -77% |
| read open | thread200 | swift_show | 200.38 (211.76) | 16.92 (23.96) | -92% |
| read open | thread200 | page_laid_out | 228.96 (241.98) | 44.92 (56.95) | -80% |
| read open | heaviest | swift_show | 199.81 (243.06) | 16.45 (24.12) | -92% |
| read open | heaviest | page_laid_out | 228.10 (273.92) | 44.51 (55.96) | -80% |
| unread open | news20 | swift_show | 6.30 (7.03) | 1.11 (1.29) | -82% |
| unread open | news20 | page_laid_out | 10.75 (12.56) | 6.14 (7.28) | -43% |
| unread open | news20 | later_bytes | 22184.00 (22184.00) | 820.00 (820.00) | -96% |
| unread open | news20 | later_page_ms | 3.00 (3.00) | 1.00 (1.00) | -67% |
| unread open | news150 | swift_show | 23.79 (32.10) | 2.50 (2.87) | -89% |
| unread open | news150 | page_laid_out | 36.59 (47.88) | 18.14 (19.31) | -50% |
| unread open | news150 | later_bytes | 157212.00 (157212.00) | 807.00 (807.00) | -99% |
| unread open | news150 | later_page_ms | 13.00 (13.00) | 0.00 (1.00) | -100% |
| unread open | plain1 | swift_show | 1.32 (1.58) | 0.82 (0.92) | -38% |
| unread open | plain1 | page_laid_out | 2.16 (4.15) | 1.98 (3.28) | -8% |
| unread open | plain1 | later_bytes | 2357.00 (2357.00) | 847.00 (847.00) | -64% |
| unread open | plain1 | later_page_ms | 1.00 (1.00) | 1.00 (1.00) | +0% |
| unread open | thread60 | swift_show | 62.78 (75.56) | 8.00 (9.32) | -87% |
| unread open | thread60 | page_laid_out | 78.15 (90.20) | 22.58 (24.14) | -71% |
| unread open | thread60 | later_bytes | 466664.00 (466664.00) | 42339.00 (42339.00) | -91% |
| unread open | thread60 | later_page_ms | 9.00 (10.00) | 9.00 (10.00) | +0% |
| unread open | thread200 | swift_show | 203.13 (213.00) | 16.45 (18.31) | -92% |
| unread open | thread200 | page_laid_out | 252.81 (269.90) | 63.21 (65.75) | -75% |
| unread open | thread200 | later_bytes | 1586075.00 (1586075.00) | 136889.00 (136889.00) | -91% |
| unread open | thread200 | later_page_ms | 28.00 (30.00) | 27.00 (29.00) | -4% |
| unread open | heaviest | swift_show | 204.16 (218.59) | 15.53 (17.02) | -92% |
| unread open | heaviest | page_laid_out | 249.91 (271.77) | 62.44 (65.50) | -75% |
| unread open | heaviest | later_bytes | 1586075.00 (1586075.00) | 136889.00 (136889.00) | -91% |
| unread open | heaviest | later_page_ms | 28.00 (31.00) | 27.00 (28.00) | -4% |
| held j | 0 | ms | 23.00 (25.67) | 13.74 (14.21) | -40% |
| held j | 0 | press_median | 5.75 (5.99) | 0.63 (0.64) | -89% |
| held j | 0 | lag_max | 247.80 (253.51) | 25.73 (25.78) | -90% |
| held j | 33 | ms | 18.11 (20.47) | 9.21 (9.88) | -49% |
| held j | 33 | press_median | 6.07 (6.09) | 0.70 (0.93) | -88% |
| held j | 33 | lag_max | 51.84 (62.95) | 13.90 (16.19) | -73% |
| memory | 1 | after the opens | 332.8 | 400.5 | +20% |
| memory | 2 | after the opens | 405.1 | 510.1 | +26% |
| read open, window shown | news20 | page_painted | 37.23 (38.40) | 15.09 (21.87) | -59% |
| read open, window shown | news150 | page_painted | 40.56 (41.20) | 24.16 (24.71) | -40% |
| read open, window shown | plain1 | page_painted | 23.39 (23.74) | 16.70 (21.67) | -29% |
| read open, window shown | thread60 | page_painted | 89.43 (94.97) | 23.76 (24.46) | -73% |
| read open, window shown | thread200 | page_painted | 228.33 (237.70) | 49.29 (50.16) | -78% |

### real snapshot (numbers only; pictures never fetched)

| scenario | shape | metric | baseline | final | change |
|---|---|---|---|---|---|
| read open | news20 | swift_show | 6.90 (7.91) | 1.26 (1.76) | -82% |
| read open | news20 | page_laid_out | 9.57 (11.82) | 4.75 (6.26) | -50% |
| read open | news150 | swift_show | 19.56 (23.97) | 1.84 (3.01) | -91% |
| read open | news150 | page_laid_out | 24.42 (29.99) | 6.58 (10.26) | -73% |
| read open | plain1 | swift_show | 0.55 (0.81) | 0.44 (0.63) | -20% |
| read open | plain1 | page_laid_out | 1.15 (2.66) | 1.10 (2.46) | -4% |
| read open | thread60 | swift_show | 23.10 (31.40) | 5.02 (6.55) | -78% |
| read open | thread60 | page_laid_out | 29.01 (37.77) | 10.86 (17.15) | -63% |
| read open | thread200 | swift_show | 24.13 (35.96) | 4.93 (6.74) | -80% |
| read open | thread200 | page_laid_out | 29.78 (42.97) | 10.71 (16.80) | -64% |
| read open | heaviest | swift_show | 53.14 (61.46) | 7.63 (10.34) | -86% |
| read open | heaviest | page_laid_out | 65.67 (75.96) | 20.33 (29.98) | -69% |
| unread open | news20 | swift_show | 6.25 (7.50) | 1.28 (1.85) | -80% |
| unread open | news20 | page_laid_out | 9.45 (13.02) | 4.53 (6.88) | -52% |
| unread open | news20 | later_bytes | 22275.00 (22275.00) | 797.00 (797.00) | -96% |
| unread open | news20 | later_page_ms | 2.00 (3.00) | 1.00 (1.00) | -50% |
| unread open | news150 | swift_show | 26.56 (28.63) | 4.00 (4.33) | -85% |
| unread open | news150 | page_laid_out | 31.59 (37.20) | 14.02 (16.05) | -56% |
| unread open | news150 | later_bytes | 161659.00 (161659.00) | 908.00 (908.00) | -99% |
| unread open | news150 | later_page_ms | 5.00 (8.00) | 1.00 (1.00) | -80% |
| unread open | plain1 | swift_show | 1.12 (1.52) | 0.87 (1.24) | -22% |
| unread open | plain1 | page_laid_out | 2.69 (7.33) | 2.69 (3.55) | +0% |
| unread open | plain1 | later_bytes | 2685.00 (2685.00) | 898.00 (898.00) | -67% |
| unread open | plain1 | later_page_ms | 1.00 (2.00) | 1.00 (1.00) | +0% |
| unread open | thread60 | swift_show | 28.98 (41.26) | 7.33 (8.63) | -75% |
| unread open | thread60 | page_laid_out | 41.36 (68.90) | 21.43 (27.80) | -48% |
| unread open | thread60 | later_bytes | 223272.00 (223272.00) | 21531.00 (21531.00) | -90% |
| unread open | thread60 | later_page_ms | 6.00 (10.00) | 6.00 (8.00) | +0% |
| unread open | thread200 | swift_show | 29.82 (39.07) | 7.56 (8.89) | -75% |
| unread open | thread200 | page_laid_out | 41.78 (53.48) | 23.02 (29.15) | -45% |
| unread open | thread200 | later_bytes | 223272.00 (223272.00) | 21531.00 (21531.00) | -90% |
| unread open | thread200 | later_page_ms | 6.00 (9.00) | 6.00 (7.00) | +0% |
| unread open | heaviest | swift_show | 56.08 (68.38) | 7.23 (9.72) | -87% |
| unread open | heaviest | page_laid_out | 70.64 (90.83) | 20.44 (29.02) | -71% |
| unread open | heaviest | later_bytes | 429336.00 (429336.00) | 884.00 (884.00) | -100% |
| unread open | heaviest | later_page_ms | 13.00 (19.00) | 1.00 (1.00) | -92% |
| held j | 0 | ms | 8.11 (33.22) | 11.70 (12.77) | +44% |
| held j | 0 | press_median | 5.16 (5.31) | 0.59 (0.66) | -89% |
| held j | 0 | lag_max | 165.89 (177.68) | 25.72 (26.91) | -84% |
| held j | 33 | ms | 14.74 (16.74) | 8.85 (9.69) | -40% |
| held j | 33 | press_median | 5.15 (5.37) | 0.84 (0.89) | -84% |
| held j | 33 | lag_max | 29.39 (35.51) | 11.94 (12.16) | -59% |
| memory | 1 | after the opens | 244.9 | 210.2 | -14% |
| memory | 2 | after the opens | 336.8 | 168.5 | -50% |
| read open, window shown | news20 | page_painted | 31.99 (33.76) | 32.39 (34.99) | +1% |
| read open, window shown | news150 | page_painted | 36.66 (39.95) | 22.93 (23.77) | -37% |
| read open, window shown | plain1 | page_painted | 26.51 (27.56) | 17.57 (17.82) | -34% |
| read open, window shown | thread60 | page_painted | 35.29 (35.63) | 23.55 (24.80) | -33% |
| read open, window shown | thread200 | page_painted | 42.92 (44.69) | 24.34 (26.46) | -43% |
| read open, window shown | heaviest | page_painted | 105.69 (106.35) | 39.65 (39.92) | -62% |

The synth memory rows are not a change: the two runs started from different idle levels (258 and 300 MB). See below.

### Looks and structure

- DOM fingerprint (every element, class, inline style and text inside the messages too, page height, scroll position)
  of all 12 synth cases (6 shapes, read and unread): identical before and after.
- In-app snapshots of the web view for the same 12 cases: byte-identical PNGs before and after.
- Real snapshot: 10 of 12 fingerprints identical. The two `news150` ones differ by one element at the same page height
  (763 and 764). The likely cause is outside these changes: the benchmark app shares `~/Library/Caches/avatars2` with
  the installed app, and 22 sender pictures were written there between the two runs, so a picture element that used
  to be removed for lack of a picture now stays. Not proven for that exact sender.
- `verify`: the new classifying of a message (rich or simple, has `cid:` pictures) against the two regular expressions
  alone: 0 differences in 50,000 synth and 2,849 real messages.
- Offline check: a plain web view given the probe HTML makes 6 connections (control), the conversation view 0.
- Core tests: 23 pass. Both schemes build with no warnings (the two in `ThreadWeb.swift` are fixed).

### iPhone simulator, final build, synth (median, p90)

| shape | swift_show | page_laid_out, read | page_laid_out, unread |
|---|---|---|---|
| news20 | 0.78 (2.11) | 3.87 (6.81) | 3.60 (5.72) |
| news150 | 1.51 (2.61) | 18.36 (30.42) | 18.27 (25.82) |
| plain1 | 0.45 (0.92) | 1.54 (16.04) | 1.21 (2.71) |
| thread60 | 5.20 (10.20) | 13.82 (23.34) | 19.76 (28.60) |
| thread200 | 20.27 (30.35) | 39.74 (188.70) | 56.35 (62.21) |

### Launch

Creating the web view to the page saying "ready": 240 to 340 ms on a quiet Mac in both builds, 0.9 to 2 s while other
builds were running (it is the web content process starting). Unchanged; nothing in the page itself is slow.

## What was kept (one commit each)

1. Byte walk before the regular expressions and the U+2028/2029 rewrite (39dadaf): 77 to 92% less main-thread time.
2. Marking read no longer rebuilds the page (ecc22f2): the second draw of a newsletter sends about 800 bytes, not all
   of it, and takes the page 1 ms.
3. Only the newest conversation waits while the page is busy (ad2acd1): held j back to back, the conversation
   you stop on is laid out 14 ms after the last press instead of 120.
4. The two compiler warnings (26cddc2). Offline block (dcc5ffe).

## Tried, did not help (not kept)

- Passing the payload as an argument (`callAsyncJavaScript`, as a JSON string or as a dictionary) instead of script
  source: no difference in memory growth; not kept.
- Memory: the web content process grows by about 1.2 MB per large newsletter opened and does not give it back on
  close or after 20 idle seconds; at about 970 MB (after 800 opens) WebKit itself drops it to about 200 MB. Emptying
  the bodies of conversations that left the page, and forcing a script garbage collection, changed nothing, and it
  is not the pictures (replacing every `<img>` lowered it by about a fifth). The real snapshot hovers at 110 to 290 MB
  without the steady climb. Cause not found; baseline and final behave the same.
- `fit()` forcing layout once per arriving picture: a newsletter whose (built-in) pictures really load used no more
  page processor time than the same size without (17 against 22 ms), so batching it was not worth a change.

## Not tried (and why)

- Sending collapsed messages without their bodies: after change 1 a 200-message thread costs 17 ms on the main
  thread, of which the bodies are about 10 (read, JSON, the call). The longest real conversation has 31 messages
  (5 ms). It needs the store to read rows without bodies (another agent's file) and makes expanding wait for a
  round trip.
- One shared style sheet for every message (`adoptedStyleSheets`) and `content-visibility` for collapsed lines: they
  would only matter for the 200-message page (26 ms of layout) and change the page's structure.
