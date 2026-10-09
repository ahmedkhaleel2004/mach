<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/mac-dark-256.png" width="96" alt="Mach icon">
</p>

<h1 align="center">Mach</h1>

<p align="center">
  The instant mail app for Gmail. Free for personal use, source open, native on Mac and iPhone.
</p>

<p align="center">
  <a href="https://github.com/ahmedkhaleel2004/mach/releases/latest"><b>Download for Mac</b></a>
  &nbsp;·&nbsp; <a href="#iphone">iPhone</a>
  &nbsp;·&nbsp; <a href="#shortcuts">Shortcuts</a>
  &nbsp;·&nbsp; <a href="bench/RESULTS.md">Benchmarks</a>
</p>

![Mach on Mac and iPhone](docs/hero.png)

Mach keeps your mail in a database on your device, so nothing you do waits for the network. Lists, conversations and
search answer before the next frame; what you did is sent to Gmail behind you. There are no spinners and almost no
animation: things are simply there.

## Fast, measured

Every number below is a median from the benchmarks in [`bench/`](bench/RESULTS.md), on a made-up mailbox of 50,000
messages. "Before" is Mach's own first version, not another app.

| | Before | Now |
|---|---|---|
| Open a 200-message conversation | 231 ms | **48 ms** |
| Open a heavy newsletter | 41 ms | **17 ms** |
| Search 50,000 messages for a word | 14 ms | **2 ms** |
| Main thread held per letter typed in search | 76 ms | **0.7 ms** |
| Move down the list, per key | 8 ms | **2.3 ms** |
| Archive 50 conversations | 50 ms | **14 ms** |
| Read the inbox from disk (600 rows) | 2.3 ms | **0.5 ms** |
| First 35 conversations on a brand-new sign-in | 3.9 s | **0.5 s** |
| App size, Mac / iPhone | 8.8 / 9.2 MB | **4.6 / 4.5 MB** |

With the relay running, new mail is on screen about a quarter of a second after Gmail announces it.

## What it feels like

- **One inbox, or all of them.** Every account in a single list, or one at a time. Split Inbox is a switch, off by default.
- **Keyboard first on Mac.** Gmail's own shortcuts, a command bar on `⌘K`, and nothing that needs the mouse.
- **Swipes on iPhone.** Left to archive, right to mark read, both changeable; one swipe, no confirm. Swipe anywhere on an
  open email to go back. Everything follows your finger at 120 Hz and ticks when it takes.
- **Undo everything.** Archive, trash, snooze, and sending for five seconds.
- **Real faces.** The sender's Google picture, or a company's certified logo, the way Gmail shows them. Tap to enlarge.
- **Attachments you can see.** A preview on every file; a tap opens it in Quick Look.
- **Search everything.** Instant on the device, with Gmail's own search folded in as you scroll. Best match, newest or oldest.
- **Drafts and snoozes live on Gmail,** so they are on every device and in Gmail itself.
- **Works offline.** Changes apply at once and go to Gmail when you are back.
- **Light and dark,** and a size slider on both platforms.

## Install

### Mac

[Download the latest release](https://github.com/ahmedkhaleel2004/mach/releases/latest), open the disk image and drag Mach
to Applications. It is signed and notarized, and keeps itself up to date. Needs an Apple silicon Mac on macOS 15 or newer.

Sign-in needs a Google key of your own for now (five minutes, once): Google only lets an app read Gmail for the public
after a paid security review, which Mach has not been through yet.

1. In the [Google Cloud console](https://console.cloud.google.com) create a project, enable the **Gmail API** and the
   **People API**, and create an OAuth client of type **Desktop app**. Add yourself as a test user.
2. Save the client's JSON as `~/Library/Application Support/Blitzmail/OAuthClient.json` and open Mach.

### iPhone

There is no App Store or TestFlight build yet, so today the iPhone app is built from source with Xcode (free Apple
account: the app lasts a week per install; paid: a year).

```sh
brew install xcodegen
git clone https://github.com/ahmedkhaleel2004/mach && cd mach
cp /path/to/your/client.json App/Resources/OAuthClient.json
cd App && xcodegen generate && open Mach.xcodeproj   # set your team, run MachPhone on your iPhone
```

Instant notifications on a closed iPhone need the small relay in [`Relay/`](Relay/README.md), on your own free
Cloudflare account. Without it the phone checks when opened and in background refresh.

## Shortcuts

| | |
|---|---|
| `j` `k` | Next, previous |
| `Enter` / `Esc` | Open / back |
| `e` | Archive |
| `#` | Trash |
| `s` | Star |
| `b` | Snooze |
| `r` `a` `f` | Reply, reply all, forward |
| `c` | Compose |
| `z` | Undo |
| `/` | Search |
| `⌘K` | Command bar |
| `1`–`9` | Switch list |
| `⌃1`–`⌃9` | Switch account |
| `?` | All shortcuts |

## How it is built

- **`Core/`** is a Swift package with no interface: the Gmail client, a SQLite store with full-text search (GRDB),
  two-way sync and the outbox. `cd Core && swift test`.
- **`App/`** is the SwiftUI app both platforms share, with a thin layer each for the Mac window and the iPhone screen.
- An open conversation is one web view that never unloads, so opening an email is a function call, not a page load.
  Each message sits in its own shadow root under a policy that runs no scripts from mail.
- Sync is shaped around Gmail's small per-minute allowance: newest mail first, changes read from Gmail's change log,
  bulk actions as one request, and an adaptive pace that never trips the limit.
- **`Relay/`** is an optional Cloudflare Worker that turns Gmail's "new mail" signal into an Apple push.
- **`bench/`** holds the benchmarks and every result, including what did not get faster.

The only Google permissions asked for are reading and changing mail, and reading contact pictures. Your mail stays on
your devices; nothing goes anywhere but Google (and your own relay, if you run one).

## Not done yet

- One-click sign-in for everyone, and an iPhone build on TestFlight.
- Writing is plain text; links become clickable and the quoted original keeps its formatting.
- A label picker.
- A switch to stop remote pictures loading (they can tell a sender you opened their mail).

## License

Free for personal and other noncommercial use, with the source open to read, change and share on the same terms
([PolyForm Noncommercial 1.0.0](LICENSE)). Using Mach in or for a business needs a commercial license:
[email Ahmed](mailto:ahmed@gitdiagram.com).

Built by [Ahmed Khaleel](https://x.com/ahmedkhaleel04), who also made [GitDiagram](https://gitdiagram.com).
