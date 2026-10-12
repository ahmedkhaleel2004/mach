# Outlook: one check, and new mail

What an Outlook account costs next to a Gmail one, before and after the check was made lighter (2026-10-11).
"Before" is the library at be51a13 built with the same harness.

## Against a pretend Outlook (`bench/sync/run.sh synth outlook`)

Outlook is played by `Core/Sources/MachFake/FakeGraph.swift`, in memory, 120 ms per round trip, every request
logged: the numbers are round trips and our own overhead, the same on any network. The Gmail column is
`bench/results/sync.md`, same harness, same 120 ms.

| Metric | Outlook before | Outlook after | Gmail |
|---|---|---|---|
| One idle check: requests | 14 | 1 | 1 |
| ... sequential round trips | 5 | 1 | 1 |
| ... wall time | 608 ms | 125 ms | 121 ms |
| A relay's signal to the new mail being stored: round trips | 6 | 2 | 2 |
| ... wall time | 733 ms | 247 ms | 249 ms |
| ... requests in the whole pass | 15 | 3 | 2 |

What changed:

- A check used to read the list of folders again (1 request), look up the seven fixed folders by name (7), and
  then ask each folder for its changes (6 with mail in them), three at a time. Now the folders are remembered,
  between launches too (they ride in the account's cursor), and one round trip asks everything at once: whether
  the list of folders changed, the top of the inbox, and every folder's change list.
- On a signal from the relay (and a push, and pull to refresh) the top of the inbox is read first, by itself: one
  small request, then the download. The full check follows.
- The third request in a signalled pass is that full check; it runs after the mail is already stored.

## Against the real thing (`bench/live/latency.py`)

One Mac on home wifi, the installed app, the real relay, six mails each, each sent by the account to itself.
"Service to app" starts when the mail first shows in the service's own inbox listing (looked at about three times
a second, so it is good to about a third of a second) and ends when it is in Mach's database.

| | Outlook, 1.0.9 | Outlook, 1.1.0 | Gmail |
|---|---|---|---|
| Service to app, median | 1.00 s | 0.52 s | 0.34 s |
| ... slowest of six | 1.50 s | 0.96 s | 0.49 s |
| Send to app, median | 4.91 s | 3.87 s | 1.02 s |

The last row is mostly Microsoft: a mail an Outlook account sends itself takes about four seconds to reach its own
inbox, against well under one at Gmail, and nothing in Mach can change that.

Also measured on the real mailbox: Outlook's change list had new mail within about a tenth of a second of the
inbox listing having it (5 mails; in 3 the change list was first). So reading the inbox first on a signal saves a
round trip's worth of time; it is not what makes the mail findable.
