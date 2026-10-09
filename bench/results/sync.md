# Sync: results

Branch `perf-sync`. Gmail is played by `Core/Sources/MachFake` (in memory, 120 ms per request, every request
logged), so nothing here touched the network. Every number is from `bench/sync/run.sh <synth|real> <name>`, which
runs on a throwaway copy of the mailbox. "Before" is the library as it was at 890c073 (the harness commit) built
with the same harness, run back to back with "after" on 2026-10-08/09. The machine was shared with five other
agents: counts (round trips, requests, units, messages) are exact; times moved by a few milliseconds between runs.

## What changed

| Metric | Command | Before (synth / real) | After (synth / real) | Change |
|---|---|---|---|---|
| First sync: first 35 inbox threads on screen, real pacing | `run.sh <box> first50` | 3.88 s / 3.87 s | 0.54 s / 0.50 s | -86% / -87% |
| First sync: first 50 inbox threads on screen, real pacing | `run.sh <box> first50` | 17.28 s / 17.21 s | 10.42 s / 10.41 s | -40% / -40% |
| First sync: first inbox thread on screen | `run.sh <box> first50` | 0.535 s / 0.498 s (4 round trips) | 0.377 s / 0.364 s (3 round trips) | -30% / -27% |
| 2,000-message inbox, first sync + backfill: units spent | `run.sh <box> initial` | 46,697 / 46,697 | 41,675 / 41,675 | -10.8% |
| ... units per stored message | same | 21.10 | 18.83 | -10.8% |
| ... requests | same | 2,217 | 1,965 | -11.4% |
| ... messages downloaded twice | same | 302 (3.19 MB) | 51 (0.25 MB) | -83% |
| ... paced time until everything is in | same | 1,066 s / 1,067 s | 891 s / 891 s | -16.5% |
| ... messages per second during the inbox pass | same | 2.68 | 2.92 | +9% |
| One idle check of 2 accounts: CPU | `run.sh <box> poll` | 65.1 ms / 2.13 ms | 2.77 ms / 0.88 ms | -96% / -59% |
| One idle check of 2 accounts: wall time | same | 154.8 ms / 122.2 ms | 122.2 ms / 121.0 ms | -21% / -1% |
| Idle change-log requests per account per hour, live connection healthy (Mac, active) | by construction, `livePollInterval` | 240 | 60 | -75% (owner's call, see below) |
| CPU to decode + make search text, mean of the mailbox's newest 400 messages | `run.sh <box> cpu` | 0.911 ms / 0.150 ms | 0.134 ms / 0.051 ms | -85% / -66% |
| ... slowest of those messages | same | 7.72 ms / 3.72 ms | 1.01 ms / 0.35 ms | -87% / -91% |
| 150 KB newsletter: record / search text (min of 200) | same (`sync.cpu.record.newsletter`, `.strip.`) | 1.95 ms / 5.79 ms | 0.36 ms / 0.53 ms | -82% / -91% |
| 60 KB notification: record / search text | same | 0.81 ms / 2.39 ms | 0.16 ms / 0.16 ms | -80% / -93% |
| 5 attachments (5 MB of metadata): record / search text | same | 0.35 ms / 0.77 ms | 0.13 ms / 0.05 ms | -64% / -93% |
| Signal to on screen, 20 new messages | `run.sh <box> signal` | 298 ms / 267 ms | 272 ms / 261 ms | -9% / -2% (inside the noise on real) |
| Signal to on screen, 40 new messages | same | 466 ms / 442 ms | 417 ms / 402 ms | -10% / -9% |

## What did not change (measured, already at the floor)

| Metric | Command | Before | After |
|---|---|---|---|
| Signal to on screen, 1 new message (synth / real) | `run.sh <box> signal` | 248.7 ms / 245.5 ms | 248.8 ms / 244.8 ms |
| ... sequential round trips | same | 2 (`history.list`, then `messages.get`) | 2 |
| ... our own time: before the first request / between the two / last answer to screen | same | 2.4 / 0.45 / 4.7 ms | 2.3 / 0.49 / 4.9 ms |
| Round trips for 20 / 40 new messages | same | 2 / 3 | 2 / 3 |
| Archive to its request leaving | `run.sh <box> outbox` | 0.8 ms / 1.0 ms | 0.9 ms / 3.3 ms (noise) |
| 50 quick archives | same | 2 requests (1 `threads.modify` + 1 `batchModify` of 49), 60 units, last leaves at 129 ms; a third request when the queue is read mid-burst | same |
| Units per message during the inbox pass alone | `run.sh <box> initial` | 20.01 | 18.29 (conversations fetched whole land more mail per unit) |

Two round trips is the minimum for new mail: the signal carries no ids (the relay announces before it has looked),
so the change log has to be asked first. Nothing runs in series before it: with nothing queued, the outbox flush and
the snooze check are two local reads (2 ms). There is no sleep or debounce on the path. A foreground download does
not wait on the allowance unless the background has drained it below 20 units.

## What got worse

- CPU of the whole 2,000-message benchmark run rose (7.9 -> 8.4 s on synth, 4.5 -> 5.7 s on real, noisy), although
  decoding got 5 to 10 times cheaper. Background downloads are now written as they arrive, so there are about 2,000
  small writes instead of 100, and each write makes every observed list read again. On a real first sync that is
  one to four small writes a second for a quarter of an hour.

## Tried, did not help, not kept

- A write per arrival for urgent downloads too: with 20 new messages the last one reached the screen later
  (286 ms with one write, 302-316 ms with a write per arrival). Urgent downloads keep one write per wave.
- Having the relay put message ids in the signal so `history.list` could be skipped: the relay announces the moment
  Gmail's notification arrives, before its own look at the change log, so it has no ids to send without delaying
  the signal by the same round trip.
- `format=metadata`/`minimal` first and bodies later: the app charges itself the same for either, so it doubles the units.
- `threads.get?format=minimal` to avoid re-sending known messages: costs a thread plus a message, more than today.
- A sliding window of 20 in flight instead of waves of 20: same throughput when paced (the allowance is the limit),
  and it would let newer mail overtake older in the queue for units.

## Not done, because it cannot be checked without calling Gmail

- `fields=` masks. Worth little: a message answer would lose `sizeEstimate`, `historyId` and `partId`; the change
  log would lose its duplicate `messages` array. A wrong mask is a 400 on every sync.
- gzip and HTTP/2. `GmailAPI` sets `Accept-Encoding: gzip` itself and URLSession decodes it; URLSession speaks
  HTTP/2 to Google on one connection (`httpMaximumConnectionsPerHost = 20` only matters for HTTP/1.1). Read from
  the code, not measured: the fake replaces the network stack.

## Reproducing the before/after

    bench/sync/run.sh synth            # all six, about 4 minutes; `real` for the snapshot
    bench/sync/run.sh synth first50    # one of: signal cpu outbox poll first50 initial

For "before", check out 890c073's `Core/Sources/MachCore/{Sync,MIME,MailService}.swift` under the current
`Core/Sources/machbench` and `Core/Sources/MachFake` (replace `mail.livePollInterval` with `60.0` in SyncBench.swift)
and run the same commands. Raw lines: `sync-baseline-*.jsonl` (first baseline, older harness, loaded machine) and
`sync-final-*.txt` (before -> after, same harness).
