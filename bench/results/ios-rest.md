# ios-rest: writing mail, search field, overlays, memory, background, size (iPhone)

Everything here was measured in a headless iPhone 18 Pro simulator (iOS 27) on a Mac that three other benchmark
agents were loading at the same time (load average 20 to 400). So:

- **Counts are exact** (views rebuilt, lookups, bytes) and are what to trust.
- **Times are main-thread processor time**, taken with the two builds in the same hold of the simulator lock. They
  moved 30% from one turn to the next; only the direction, repeated over three turns, is claimed.
- Nothing here is a real iPhone's speed.

Re-run: `bench/ios-rest/run.sh synth|real "<scenarios>"` (scenarios: compose reply send search overlays memory idle
looks shots warm:<how>), two builds side by side with `bench/ios-rest/ab.sh <before.app> <after.app> synth "compose:3"`.

## Kept

| What | How it is measured | Before | After | Change | Kind |
|---|---|---|---|---|---|
| Root view (and the list behind) rebuilt per letter typed in To / Subject / body | `run.sh synth compose` (`n_PhoneRoot`), same on real | 1 | 0 | gone | count |
| Root view rebuilt per letter typed in search | `run.sh synth search` (`n_PhoneRoot`) | 1.2 | 0.2 (only when the results change) | -83% | count |
| Root view rebuilt per toast shown / hidden | `run.sh synth overlays` (`toast.*`, `n_PhoneRoot`) | 1 / 1 | 0 / 0 | gone | count |
| Toast shown / hidden, main thread | `toast.show` / `toast.hide` | 6.8 to 10.7 / 4.1 to 9.9 ms | 1.9 / 0.9 ms (final build) | about -75% | time, separate turns |
| A letter in Subject / body / 2,000-character body / To, synth | `compose.type.*` | 6.4 / 6.7 / 10.6 / 10.6 ms | 4.7 / 5.0 / 8.7 / 7.2 ms | about -25% | time, see note 1 |
| A letter in the body, real | same on `real` | 6.8 ms | 5.8 ms | about -15% | time, note 1 |
| Reply / forward open, first frame, real (200-message thread) | `run.sh real reply` (`cpu_first_frame`) | 59 / 68 ms | 34 / 34 ms | about -45% | time, note 1 |
| Footprint after scrolling 1,000 rows, every sender pictured | `PICTURES=1 run.sh synth memory` (`mem.scrolled_1000`) | 50.3 MB | 41.8 MB | -17% | one run each |
| Footprint after 20 conversations opened and closed | same (`mem.closed`) | 58.6 MB | 48.3 MB | -18% | one run each |
| Footprint at launch | same (`mem.launch`) | 33.8 MB | 33.8 MB | 0 | |
| Freed by a memory warning | same (`mem.idle` to `mem.after_warning`) | nothing of ours | 1.5 MB | | one run |
| Relay registrations for 20 opens in a day, nothing changed | by reading the code; decision unit-tested (`RelayRegistrationTests`) | 21, each carrying every refresh token | 2 | -90% | count |
| Sync-all + reconnect attempts per hour with no network | by reading the code | 120 | 12 (and at once when the network returns) | -90% | count |
| Extra full sync + WebSocket reconnect per inactive to active blip | by reading the code | 1 + 1 | 0 + 0 | gone | count |
| Accounts synced per push, N accounts | by reading the code | N | 1 | | count |
| Asset catalog in the iPhone app | `ls -l Mach.app/Assets.car` | 82,328 B | 41,272 B | -50% | bytes |
| Test hook reachable on a build that can reach real mail | by reading the code | yes | no (needs `MACH_OFFLINE=1`) | | |

Note 1: these times were taken on a build that also split the compose fields into separate views (dropped, see
below); the kept change is the part that removed the root-view rebuild. The final build's counts are in the table
(confirmed on it: `n_PhoneRoot` 0 per compose letter, 0.2 per search letter, 0 per toast). Its own typing times were
only taken once, with no baseline in the same turn (6.8 / 6.9 / 6.2 / 10.8 ms for To / Subject / body / long body on a
turn where every number ran high), so the size of the typing gain on the final build is not proven; the count is.

Screenshots (made-up mailbox) of the list, toast, search, empty compose and the accounts, lists, more and command
overlays are byte-identical before and after (`bench/ios-rest/shots.sh compare`). Compose with text and the snooze
sheet differ only by things that change by themselves (the text cursor and keyboard, the clock times in the sheet);
the compose view's own code is unchanged in the kept version.

## Healthy already (measured, left alone)

- "To" suggestions: one address lookup per letter typed in To and none while typing anywhere else (`n_contactsLookup`):
  the lookup only runs for the field that has the keyboard. 0.1 to 0.3 ms each.
- Send: the call returns in 0.06 to 0.10 ms and the view is gone on the next frame, on both mailboxes.
- The keyboard is asked for in the same frame compose appears (`responder` equals `first_frame`). What remains
  until it is up (about 400 ms) is the system's own slide.
- Snooze, accounts, lists and "more" overlays: 4 to 9 ms to open, rebuilding only the overlay layer.
- The notification extension: 118 KB, does not link the database library.
- Round one already tried `-Osize`, thin LTO and dead-code stripping for the app: not repeated.

## Tried, did not help (not in the branch)

- **Compose fields as separate `.equatable()` views**, so a letter in the body would not rebuild the recipient rows:
  the counters showed every field still rebuilt on every letter, with the bindings held directly, built inside the
  field, or boxed in an object. Reverted.
- **Starting the text system ahead of time** (an invisible field taking the keyboard a second after launch): as an
  experiment right before the first compose it cut that first open from 153 to 71 ms; shipped the natural way
  (a second after the app comes to the front) it cost 127 to 142 ms of main thread and the first open was no faster
  (190 to 227 ms against 132). Removed. `warm:<how>` in the benchmark keeps the experiment.
- **Database cache size / reader count for memory**: not measured. SQLite's memory counters read 0 in the app (the
  system library has them switched off), and reasoning says the win is small (reads go through the memory map, not
  the page cache). `Store.init` is unchanged.

## Not done, in order of what I would do next

1. Search: each letter runs the full-text lookup on the main thread, 25 ms on the 50,000-message mailbox (3 ms on
   real). That is 90% of a search keystroke. (List / database agents.)
2. Decode sender pictures at the size they are drawn (138 pixels) instead of 288: each is 332 KB decoded, so the
   8 MB cache holds only 24. (List agent owns rows; needs before/after screenshots with pictures.)
3. A real profile of what is left of a compose keystroke (about 5 ms in the simulator against 0.1 ms idle);
   `SAMPLE=<file> run.sh synth compose` takes one.
4. GRDB closes every reader connection when the app goes to the background; the first reads after coming back
   reopen them. Worth timing on resume (launch agent).
5. Idle energy on a real phone with the relay connected (the simulator run is offline, so it shows only 30
   wake-ups a minute from the screen side).

## Needs a real iPhone or the relay to confirm

The three connection changes (registration, waiting for the network, no reconnect on inactive), the per-account
push sync and the haptics change could not be exercised here: no network calls, no relay, and the simulator has no
tick motor. Each is its own commit and can be dropped alone.
