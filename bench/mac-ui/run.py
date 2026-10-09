#!/usr/bin/env python3
"""Benchmarks for the Mac window: launch, cursor keys, scrolling, switching lists, actions, command bar, search.

    bench/mac-ui/run.py <scenario[,scenario]|all> [--data synth|real] [--runs N] [--app PATH] [--against PATH] [--json]

Every run makes a throwaway copy of the mailbox under build/run/, starts the benchmark app in the background
(offline, on its own debug channel), lets the app play a script of keys (see App/Mac/BenchHook.swift), reads
bench.jsonl and stops the app by the process id it wrote. Numbers are milliseconds of main-thread time.
Set BLITZ_BENCH_DATA to where the master mailboxes are (default build/data). Never touches real mail or Gmail.
"""
import argparse, json, os, signal, statistics, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHANNEL = "app.blitzbench.mac-ui"
SIZE = "size:1180x780"


def many(count, *commands):
    return list(commands) * count


def scenarios(data):
    words = "kalo ren" if data == "synth" else "the mee"
    # Moves that stay on screen (no scrolling), then long runs that scroll a row a press.
    cursor = [SIZE, "g", "a", "wait:300"] + many(4, "repeat:15:cursor.inview.j:j", "repeat:15:cursor.inview.k:k")
    for rows in (300, 1000, 3000):
        cursor += [f"limit:{rows}", "wait:500", f"repeat:250:cursor.j.{rows}:j", f"repeat:250:cursor.k.{rows}:k"]
    # Deep in a long list: page down to about row 1400, then single steps there.
    cursor += ["repeat:70:cursor.page.3000:special:pageDown", "repeat:250:cursor.j.3000deep:j"]
    # Conversations are only ever opened on the made-up mailbox: the web view would fetch a real message's remote images.
    opened = ["special:enter", "wait:500"] + many(8, "settle:act.done.open:500:e") + ["special:escape", "wait:200"] if data == "synth" else []
    return {
        # Nothing but starting up. The app records its own launch marks.
        "launch": {"script": ["info"], "runs": 12},
        "cursor": {"script": cursor, "runs": 3},
        # Not a timing: random bursts of cursor keys, counting the times the row under the cursor ended up out of view.
        "stress": {"script": [SIZE, "wait:300", "stress:1", "g", "a", "wait:300", "stress:11"], "runs": 3},
        "scroll": {"script": [SIZE, "g", "a", "wait:300", "limit:1000", "wait:500", "scroll:100:380", "wait:200", "scroll:100:-380", "wait:200",
                              "scroll:100:38", "scroll:100:-38"], "runs": 3},
        "switch": {"script": [SIZE] + many(8, "g", "settle:switch.go.all:300:a", "g", "settle:switch.go.sent:300:t", "g", "settle:switch.go.inbox:300:i")
                   + many(8, "settle:switch.account.one:300:ctrl:1", "settle:switch.account.all:300:ctrl:0"), "runs": 2},
        "tab": {"script": [SIZE] + many(12, "settle:switch.tab:300:special:tab"), "runs": 2, "split": True},
        "actions": {"script": [SIZE] + many(10, "settle:act.done:400:e") + many(10, "settle:act.undo:400:z")
                    + many(10, "settle:act.star:400:s") + many(10, "settle:act.unread:400:U")
                    + many(4, "select:50", "settle:act.done50:600:e", "settle:act.undo50:600:z")
                    + opened
                    + ["g", "s", "wait:300", "churn:20"], "runs": 2},
        "palette": {"script": [SIZE] + many(10, "key:palette.open:cmd:k", "special:escape") + many(3, "palette:go to sent"), "runs": 2},
        "search": {"script": [SIZE] + many(2, f"search:{words}"), "runs": 2},
    }


def launch(app, data, script, split=False, fresh=True, name="run", shot=None):
    folder = os.path.join(ROOT, "build", "run", f"mac-ui-{name}")
    if fresh or not os.path.exists(folder):
        subprocess.run([os.path.join(ROOT, "bench", "data.sh"), "fresh", data, folder], check=True)
    log = os.path.join(folder, "bench.jsonl")
    if os.path.exists(log):
        os.remove(log)
    subprocess.run(["open", "-g", "-n", app, "--env", f"BLITZ_DATA_DIR={folder}", "--env", "BLITZ_OFFLINE=1", "--env", f"BLITZ_DEBUG_CHANNEL={CHANNEL}",
                    "--env", "BLITZ_BENCH_SCRIPT=" + ";".join(script + ["done"]),
                    "--args", "-scope", "all", "-splitInbox", "YES" if split else "NO", "-showAvatars", "YES", "-ApplePersistenceIgnoreState", "YES"], check=True)
    records, pid, deadline = [], None, time.time() + 600
    try:
        while time.time() < deadline:
            time.sleep(0.25)
            if not os.path.exists(log):
                continue
            with open(log) as handle:
                records = [json.loads(line) for line in handle if line.strip()]
            pid = next((r["pid"] for r in records if r["metric"] == "launch.pid"), pid)
            window = next((r["window"] for r in records if r["metric"] == "info"), None)
            if shot and window:
                # The window's own pixels, without its shadow, wherever it is on screen and whatever covers it.
                time.sleep(0.5)
                subprocess.run(["screencapture", "-x", "-o", "-l", str(window), shot], check=True)
                shot = None
            if any(r["metric"] == "done" for r in records):
                break
        else:
            raise SystemExit("timed out waiting for the app; see " + log)
    finally:
        # Only ever the process this run started.
        if pid:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    time.sleep(0.3)
    return [r for r in records if r["metric"] not in ("done", "launch.pid")]


def summarise(records):
    """One line per metric: the median and 90th centile over every sample, plus the extra fields' medians."""
    grouped = {}
    for record in records:
        grouped.setdefault(record["metric"], []).append(record)
    out = {}
    for metric, items in grouped.items():
        if metric == "info":
            continue
        values = sorted(r["ms"] for r in items)
        line = {"n": len(values), "median": round(statistics.median(values), 3), "p90": round(values[min(len(values) - 1, len(values) * 9 // 10)], 3)}
        for key in ("p90", "max", "busy", "afterTyping", "maxTurn", "over8", "over16", "applies", "skipped", "rows"):
            extra = [r[key] for r in items if key in r]
            if extra:
                line["step_p90" if key == "p90" else key] = round(statistics.median(extra), 3)
        out[metric] = line
    return out


def main():
    # Copies of a mailbox are readable by their owner only.
    os.umask(0o077)
    os.makedirs(os.path.join(ROOT, "build", "run"), mode=0o700, exist_ok=True)
    os.chmod(os.path.join(ROOT, "build"), 0o700)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario")
    parser.add_argument("--data", default="synth", choices=["synth", "real"])
    parser.add_argument("--runs", type=int)
    parser.add_argument("--app", default=os.path.join(ROOT, "build", "dd-mac", "Build", "Products", "Release", "Mach.app"))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--against", help="another build of the app to run in turn with this one, for a before/after table")
    parser.add_argument("--script", help="with the scenario name 'custom': the commands to play, separated by ;")
    args = parser.parse_args()
    if not os.path.exists(args.app):
        raise SystemExit("build the app first: bench/build.sh mac")
    if args.scenario == "shot":
        # A picture of the window in a fixed state (cursor moved, one row ticked), to compare before and after a change.
        # Only ever of the made-up mailbox.
        target = os.path.join(ROOT, "build", "shots", time.strftime("%H%M%S") + ".png")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        keys = args.script.split(";") if args.script else ["j", "j", "j", "x", "j", "s"]
        launch(args.app, "synth", [SIZE] + keys + ["wait:1500", "info", "wait:1500"], name="shot", shot=target)
        print(target)
        return
    table = scenarios(args.data)
    if args.script:
        table["custom"] = {"script": args.script.split(";"), "runs": 1}
    names = [name for name in table if name != "stress"] + ["relaunch"] if args.scenario == "all" else args.scenario.split(",")
    # With --against, each run of the build under test is followed by a run of the other build, so both see the same machine load.
    apps = [args.app] + ([args.against] if args.against else [])
    results = [{} for _ in apps]
    for name in names:
        # "relaunch" starts again on the same copy of the mailbox, so the database file is already in memory.
        spec = table["launch" if name == "relaunch" else name]
        records = [[] for _ in apps]
        for index in range(args.runs or spec["runs"]):
            for which, app in enumerate(apps):
                records[which] += launch(app, args.data, spec["script"], split=spec.get("split", False), fresh=name != "relaunch" or index == 0,
                                         name=name + ("-against" if which else ""))
        for which in range(len(apps)):
            summary = summarise(records[which])
            # Every run records its own start-up; only the launch scenarios report it.
            if name not in ("launch", "relaunch"):
                summary = {key: value for key, value in summary.items() if not key.startswith("launch.")}
            if name == "relaunch":
                summary = {key.replace("launch.", "relaunch."): value for key, value in summary.items()}
            results[which].update(summary)
    result = results[0]
    if args.json:
        print(json.dumps({"now": result, "against": results[1]} if args.against else result, indent=1, sort_keys=True))
        return
    if args.against:
        print(f"{'metric':28} {'against':>9} {'now':>9} {'change':>8}   {'busy: against':>13} {'now':>8}   applies: against, now")
        for metric in sorted(result):
            now, old = result[metric], results[1].get(metric)
            if not old:
                continue
            change = (now["median"] - old["median"]) / old["median"] * 100 if old["median"] else 0
            print(f"{metric:28} {old['median']:>9.2f} {now['median']:>9.2f} {change:>+7.1f}%   {old.get('busy', '-')!s:>13} {now.get('busy', '-')!s:>8}   "
                  f"{old.get('applies', '-')}, {now.get('applies', '-')}")
        return
    print(f"{'metric':34} {'n':>4} {'median':>9} {'p90':>9}  extra")
    for metric in sorted(result):
        line = result[metric]
        extra = "  ".join(f"{key}={value}" for key, value in line.items() if key not in ("n", "median", "p90"))
        print(f"{metric:34} {line['n']:>4} {line['median']:>9.3f} {line['p90']:>9.3f}  {extra}")


if __name__ == "__main__":
    main()
