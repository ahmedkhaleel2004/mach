# Benchmarks

Everything here measures Mach without touching real mail or Gmail.

## Rules (read before running anything)

- Never run a build against `~/Library/Application Support/Mach`. Benchmarks run on copies under `build/` (git-ignored).
- Never kill, replace or signal the installed app. Stop a test app **by the process id you started**, never by name.
- Never install on a phone, deploy the relay, push to a remote, or call Gmail. `MACH_OFFLINE=1` is set on every run.
- Never put real subjects, senders or bodies in a commit, a log you keep, or a report. Numbers only.
- Launch test apps in the background (`open -g -n`), so they do not take the keyboard. Keep them short-lived.

## Pieces

- `bench/data.sh` builds the two master mailboxes in `build/data` (or `$MACH_BENCH_DATA`): `synth` (50,000 made-up
  messages, the same every time) and `real` (a read-only snapshot of the real mailbox). `bench/data.sh fresh synth <dir>`
  makes an instant throwaway copy to run against. Never run against the masters.
- `bench/build.sh mac|ios` builds the benchmark app: Release, `BENCH` defined, bundle id `com.ahmedkhaleel.machbench.*`, unsigned.
  It refuses to start without `MACH_DATA_DIR`. `DD=<folder>` picks the build folder.
- `Core/Sources/machbench` is the headless tool: `machbench generate <dir>`, and one file per benchmark for the
  parts with no screen (`measure(...)` prints the median and p90 as a JSON line).
- `bench/sync/run.sh [synth|real] [signal|cpu|outbox|poll|first50|initial]` runs the sync benchmarks. Gmail is played
  by `Core/Sources/MachFake` (in memory, 120 ms per request, every request logged); results in `bench/results/sync.md`.
- `App/Shared/Bench.swift` (`DEBUG || BENCH` only): `Bench.record(metric, ms:)` appends to `bench.jsonl` in the data
  folder; `Bench.once(metric)` records time since process start.

## Running the Mac app for a measurement

    app=$(bench/build.sh mac)
    bench/data.sh fresh synth build/run/x
    open -g -n "$app" --env MACH_DATA_DIR="$PWD/build/run/x" --env MACH_OFFLINE=1 --env MACH_DEBUG_CHANNEL=com.ahmedkhaleel.machbench.x
    # press keys without focus (see the hook in App/Mac/MacApp.swift):
    swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.ahmedkhaleel.machbench.x"), object: "j", userInfo: nil, deliverImmediately: true)'

Web content does not paint in a hidden window; time it from inside the page, or bring the window forward for at
most a second with the `front` command and send it `back` again.

## Keyboard focus

`bench/mac-ui/focus.sh` presses real keys (command bar, reply, search, new message) in a benchmark copy and checks
after each that the keyboard is where it should be. It is the one script here that comes to the front, for about
ten seconds: focus only goes wrong in the key window with real key events. Run it after touching anything that
opens a text field.

## Results

`bench/RESULTS.md` is the table: metric, how it is measured, baseline, final, change, for Mac and iPhone, on both mailboxes.
