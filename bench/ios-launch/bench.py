#!/usr/bin/env python3
"""How fast the iPhone app gets to a usable screen, in every way it can start. Simulator only.

    bench/ios-launch/bench.py launch  synth|real|empty|wal [runs]     cold launches of one build (default 15)
    bench/ios-launch/bench.py open    synth|real [runs]               cold launch straight into a conversation (the notification path)
    bench/ios-launch/bench.py ab      <A.app> <B.app> synth|real|empty|wal [runs] [open]    two builds, launched in turn
    bench/ios-launch/bench.py resume  synth|real [rounds]             to the background and back
    bench/ios-launch/bench.py webkill synth|real                      the conversation page thrown away and loaded again
    bench/ios-launch/bench.py push    synth                           a silent push, to the running app and to one that is not running
    bench/ios-launch/bench.py notify  [rounds]                        how long the notification extension holds a banner (good network, bad, none)
    bench/ios-launch/bench.py shots   <folder>                       first-screen and launch-screen pictures, light and dark (synth)
    bench/ios-launch/bench.py sample  synth|real <out.txt>            where the main thread's time goes during a launch
    bench/ios-launch/bench.py down                                    shut the simulator down

Needs MACH_BENCH_DATA (the folder holding synth/ and real/). APP=<Mach.app> uses a build instead of making one
(`DD=build/dd-ios-launch bench/build.sh ios`). Everything runs offline in a simulator of its own (MachBench-ios-launch),
on throwaway copies of the mailboxes under build/run/. For `real`, numbers only are printed.

Mailboxes: `empty` is a first run (no database: the welcome screen); `wal` is the synth mailbox as a crash would leave
it, with about 300 MB of changes still sitting in the write-ahead log.

Launch times are milliseconds since the system started the process, taken inside the app (`App/iOS/LaunchBench.swift`).
Each has two columns: the clock, and the main thread's own processor time (steadier in a simulator: trust it first).
Simulator numbers are not iPhone numbers; compare two builds with `ab`, never a number from one day with another.
"""
import json
import os
import plistlib
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEVICE = "MachBench-ios-launch"
BUNDLE = "com.ahmedkhaleel.machbench.ios"
RUN = os.path.join(ROOT, "build/run")
DATA = os.environ.get("MACH_BENCH_DATA") or os.path.join(ROOT, "build/data")
MARKS = ["launch.host", "launch.service", "launch.model.web", "launch.model.accounts", "launch.model.list", "launch.model",
         "launch.hostReady", "launch.firstFrame", "launch.idle", "thread_web_ready", "launch.openCalled", "launch.openShown"]
# The stretches of a launch that are the app's own doing. Everything before `launch.host` is the system loading
# libraries, which a simulator does by hand and slowly: it is reported, but it is not what `ab` is for.
SPANS = [("open database", "launch.host", "launch.service"), ("make web view", "launch.service", "launch.model.web"),
         ("read accounts", "launch.model.web", "launch.model.accounts"), ("read first list", "launch.model.accounts", "launch.model.list"),
         ("rest of start-up code", "launch.model.list", "launch.hostReady"), ("our start-up code, all", "launch.host", "launch.hostReady"),
         ("start-up code → first frame", "launch.hostReady", "launch.firstFrame"), ("first frame → idle", "launch.firstFrame", "launch.idle"),
         ("OUR CODE → FIRST FRAME", "launch.host", "launch.firstFrame"), ("OUR CODE → TAPPABLE", "launch.host", "launch.idle"),
         ("our code → web view ready", "launch.host", "thread_web_ready"), ("first frame → web view ready", "launch.firstFrame", "thread_web_ready"),
         ("our code → conversation shown", "launch.host", "launch.openShown"), ("process start → first frame", None, "launch.firstFrame"),
         ("process start → conversation shown", None, "launch.openShown")]


def sh(*args, env=None, check=True, quiet=False):
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    if check and result.returncode != 0 and not quiet:
        sys.exit(f"{' '.join(args)}\n{result.stderr}")
    return result.stdout.strip()


def device():
    listing = json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))
    for runtime in listing["devices"].values():
        for entry in runtime:
            if entry["name"] == DEVICE:
                return entry["udid"], entry["state"]
    return sh("xcrun", "simctl", "create", DEVICE, "iPhone 18 Pro"), "Shutdown"


def boot():
    udid, state = device()
    if state != "Booted":
        sh("xcrun", "simctl", "boot", udid)
    sh("xcrun", "simctl", "bootstatus", udid)
    return udid


def build():
    if os.environ.get("APP"):
        return os.environ["APP"]
    env = dict(os.environ, DD="build/dd-ios-launch", MACH_DATA_DIR="/nonexistent")
    return sh(os.path.join(ROOT, "bench/build.sh"), "ios", env=env).splitlines()[-1]


def install(udid, app, bundle=BUNDLE):
    """Installs a copy of the build under `bundle`, so two builds can sit side by side."""
    copy = os.path.join(RUN, "apps", bundle + ".app")
    shutil.rmtree(copy, ignore_errors=True)
    os.makedirs(os.path.dirname(copy), exist_ok=True)
    shutil.copytree(app, copy, symlinks=True)
    plists = [(os.path.join(copy, "Info.plist"), bundle)]
    extension = os.path.join(copy, "PlugIns/MachNotify.appex/Info.plist")
    if os.path.exists(extension):
        plists.append((extension, bundle + ".notify"))
    for path, identifier in plists:
        with open(path, "rb") as file:
            info = plistlib.load(file)
        info["CFBundleIdentifier"] = identifier
        with open(path, "wb") as file:
            plistlib.dump(info, file, fmt=plistlib.FMT_BINARY)
    sh("xcrun", "simctl", "install", udid, copy)
    return bundle


def fresh(box, name):
    """A throwaway copy of a mailbox. Returns its folder."""
    target = os.path.join(RUN, "ios-launch-" + name)
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target, mode=0o700)
    if box == "empty":
        return target
    source = "synth" if box == "wal" else box
    sh(os.path.join(ROOT, "bench/data.sh"), "fresh", source, target, env=dict(os.environ, MACH_BENCH_DATA=DATA))
    if box == "wal":
        big_wal(target)
    return target


def big_wal(folder):
    """Leaves the copy the way a crash would: hundreds of megabytes written but never folded back into the main file."""
    path = os.path.join(folder, "mail.sqlite")
    db = sqlite3.connect(path, isolation_level=None)
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA wal_autocheckpoint = 0")
    db.execute("BEGIN")
    db.execute("UPDATE message SET snippet = snippet || ' ' WHERE rowid IN (SELECT rowid FROM message ORDER BY rowid LIMIT 12000)")
    db.execute("UPDATE thread SET snippet = snippet || ' '")
    db.execute("COMMIT")
    # Copied while the connection is still open: closing it would tidy the log away, which a crash never does.
    for suffix in ("-wal", "-shm"):
        shutil.copyfile(path + suffix, path + suffix + ".crash")
    db.close()
    for suffix in ("-wal", "-shm"):
        os.replace(path + suffix + ".crash", path + suffix)
    return os.path.getsize(path + "-wal")


def lines(folder):
    try:
        with open(os.path.join(folder, "bench.jsonl")) as file:
            return [json.loads(line) for line in file if line.strip()]
    except FileNotFoundError:
        return []


def wait_done(folder, command, count=1, seconds=240):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = [line for line in lines(folder) if line.get("metric") == "done" and line.get("cmd") == command]
        if len(found) >= count:
            return True
        time.sleep(0.05)
    return False


def start(udid, bundle, folder, extra=None):
    env = dict(os.environ, SIMCTL_CHILD_MACH_DATA_DIR=folder, SIMCTL_CHILD_MACH_OFFLINE="1",
               SIMCTL_CHILD_MACH_DEBUG_CHANNEL="com.ahmedkhaleel.machbench.ios-launch")
    for key, value in (extra or {}).items():
        env["SIMCTL_CHILD_" + key] = value
    asked = time.time() * 1000
    sh("xcrun", "simctl", "launch", udid, bundle, env=env)
    return asked


def stop(udid, bundle):
    sh("xcrun", "simctl", "terminate", udid, bundle, check=False, quiet=True)
    time.sleep(0.4)


def one_launch(udid, bundle, folder, opening=False, switches=""):
    """One cold launch. Returns {mark: (ms since process start, main-thread ms)} plus the counts."""
    stop(udid, bundle)
    log = os.path.join(folder, "bench.jsonl")
    if os.path.exists(log):
        os.remove(log)
    extra = {"MACH_LAUNCH_OPEN": "1"} if opening else {}
    if switches:
        extra["MACH_EXP"] = switches
    asked = start(udid, bundle, folder, extra)
    if not wait_done(folder, "launch"):
        stop(udid, bundle)
        return None
    time.sleep(0.2)
    found = {line["metric"]: line for line in lines(folder)}
    stop(udid, bundle)
    result = {name: (found[name]["ms"], found[name].get("cpu", 0)) for name in MARKS if name in found}
    host = found.get("launch.host")
    if host:
        # From the launch being asked for to the process existing: the system's share, not the app's.
        result["asked→process"] = (host["wall"] - host["ms"] - asked, 0)
    done = found["done"]
    first = found.get("launch.firstFrame", {})
    result["counts"] = {"listApplies": done.get("listApplies"), "emptyTicks": done.get("emptyTicks"), "rows": first.get("rows"),
                        "tick": first.get("tick"), "cpuAll": done.get("cpuAll"), "footprint": done.get("footprint"),
                        "appliesAtFrame": first.get("listApplies"), "chars": found.get("launch.openShown", {}).get("chars")}
    return result


def middle(values):
    values = sorted(values)
    return values[len(values) // 2]


def p90(values):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(0.9 * (len(values) - 1))))]


def summary(runs):
    out = {}
    for label, begin, end in SPANS:
        pairs = [(run[end][0] - (run[begin][0] if begin else 0), run[end][1] - (run[begin][1] if begin else 0))
                 for run in runs if end in run and (begin is None or begin in run)]
        if pairs:
            clock, cpu = [pair[0] for pair in pairs], [pair[1] for pair in pairs]
            out[label] = {"cpu": round(middle(cpu), 1), "cpu_p90": round(p90(cpu), 1), "cpu_min": round(min(cpu), 1),
                          "ms": round(middle(clock), 1), "ms_p90": round(p90(clock), 1), "ms_min": round(min(clock), 1), "n": len(clock)}
    asked = [run["asked→process"][0] for run in runs if "asked→process" in run]
    if asked:
        out["asked → process exists"] = {"cpu": 0, "cpu_p90": 0, "cpu_min": 0, "ms": round(middle(asked), 1), "ms_p90": round(p90(asked), 1),
                                         "ms_min": round(min(asked), 1), "n": len(asked)}
    counts = {}
    for key in runs[0]["counts"]:
        values = [run["counts"][key] for run in runs if run["counts"].get(key) is not None]
        if values:
            counts[key] = round(middle(values), 1) if isinstance(values[0], float) else sorted(set(values))
    out["counts"] = counts
    return out


def show(label, table):
    print(f"\n{label}")
    print(f"  {'stretch':34} {'main cpu ms':>11} {'p90':>7} {'min':>7}   {'clock ms':>8} {'p90':>7} {'min':>7} {'n':>3}")
    for name, row in table.items():
        if name == "counts":
            continue
        print(f"  {name:34} {row['cpu']:11.1f} {row['cpu_p90']:7.1f} {row['cpu_min']:7.1f}   {row['ms']:8.1f} {row['ms_p90']:7.1f} {row['ms_min']:7.1f} {row['n']:3d}")
    print("  counts:", json.dumps(table["counts"]))


def launches(udid, bundle, folder, runs, opening=False):
    one_launch(udid, bundle, folder, opening)          # the first start after an install is not counted
    results = []
    for _ in range(runs):
        result = one_launch(udid, bundle, folder, opening)
        if result:
            results.append(result)
    return results


def load():
    return sh("sysctl", "-n", "vm.loadavg")


def command_launch(box, runs, opening=False):
    udid = boot()
    bundle = install(udid, build())
    folder = fresh(box, box)
    results = launches(udid, bundle, folder, runs, opening)
    show(f"{'open' if opening else 'launch'} {box}: {len(results)} launches, load {load()}", summary(results))
    print(json.dumps({"scenario": "open" if opening else "launch", "box": box, "summary": summary(results)}))


def command_ab(app_a, app_b, box, runs, opening):
    udid = boot()
    bundles = [install(udid, app_a, "com.ahmedkhaleel.machbench.launcha"), install(udid, app_b, "com.ahmedkhaleel.machbench.launchb")]
    folders = [fresh(box, box + "-a"), fresh(box, box + "-b")]
    # For trying a change that sits behind a switch in a build made for the purpose: SWITCH_A / SWITCH_B become
    # MACH_EXP in each side's launches. Unset, as for every committed build, they do nothing.
    switches = [os.environ.get("SWITCH_A", ""), os.environ.get("SWITCH_B", "")]
    results = [[], []]
    for index in (0, 1):
        one_launch(udid, bundles[index], folders[index], opening, switches[index])
    # Every round is saved as it finishes, so a run that is cut short still counts: `bench.py report <file>`.
    raw = os.path.join(RUN, os.environ.get("RAW", "ab-rounds.jsonl"))
    if os.path.exists(raw) and not os.environ.get("RAW_APPEND"):
        os.remove(raw)
    for round_number in range(runs):
        # Who goes first swaps every round, so neither build always follows the other.
        order = (0, 1) if round_number % 2 == 0 else (1, 0)
        pair = {index: one_launch(udid, bundles[index], folders[index], opening, switches[index]) for index in order}
        print(f"  round {round_number + 1}/{runs}", file=sys.stderr, flush=True)
        if pair[0] and pair[1]:
            results[0].append(pair[0])
            results[1].append(pair[1])
            with open(raw, "a") as file:
                file.write(json.dumps({"a": pair[0], "b": pair[1]}) + "\n")
    report(results, f"{app_a} {switches[0]}", f"{app_b} {switches[1]}", f"{box}{' (open)' if opening else ''}")


def command_report(raw):
    results = [[], []]
    with open(raw) as file:
        for line in file:
            pair = json.loads(line)
            results[0].append(pair["a"])
            results[1].append(pair["b"])
    report(results, "A", "B", raw)


def report(results, name_a, name_b, what):
    tables = [summary(results[0]), summary(results[1])]
    show(f"A {name_a}", tables[0])
    show(f"B {name_b}", tables[1])
    print(f"\nA against B on {what}, launched in turn, {len(results[0])} each, load {load()}")
    print("  `B-A` is the middle of the differences between each round's two launches (main-thread cpu ms), and how many rounds B won.")
    print(f"  {'stretch':34} {'A cpu':>8} {'B cpu':>8} {'change':>7} {'B-A':>7} {'B wins':>7}   {'A min':>7} {'B min':>7}   {'A clock':>8} {'B clock':>8} {'change':>7}")
    paired = {}
    for label, begin, end in SPANS:
        gaps = []
        for a, b in zip(results[0], results[1]):
            if end in a and end in b and (begin is None or (begin in a and begin in b)):
                gaps.append((b[end][1] - (b[begin][1] if begin else 0)) - (a[end][1] - (a[begin][1] if begin else 0)))
        if gaps:
            paired[label] = {"gap": round(middle(gaps), 2), "wins": sum(1 for gap in gaps if gap < 0), "n": len(gaps)}
    for name in tables[0]:
        if name == "counts" or name not in tables[1]:
            continue
        a, b = tables[0][name], tables[1][name]
        cpu = f"{(b['cpu'] - a['cpu']) / a['cpu'] * 100:+.0f}%" if a["cpu"] else ""
        clock = f"{(b['ms'] - a['ms']) / a['ms'] * 100:+.0f}%" if a["ms"] else ""
        gap = paired.get(name)
        gap_text = f"{gap['gap']:+7.1f} {str(gap['wins']) + '/' + str(gap['n']):>7}" if gap and a["cpu"] else " " * 15
        print(f"  {name:34} {a['cpu']:8.1f} {b['cpu']:8.1f} {cpu:>7} {gap_text}   {a['cpu_min']:7.1f} {b['cpu_min']:7.1f}   {a['ms']:8.1f} {b['ms']:8.1f} {clock:>7}")
    print(json.dumps({"scenario": "ab", "what": what, "A": tables[0], "B": tables[1], "paired": paired}))


def spread(folder, metric, field="ms"):
    values = [line[field] for line in lines(folder) if line.get("metric") == metric and field in line]
    if not values:
        return None
    return {"median": round(middle(values), 2), "p90": round(p90(values), 2), "min": round(min(values), 2), "n": len(values)}


def command_resume(box, rounds):
    udid = boot()
    bundle = install(udid, build())
    folder = fresh(box, box)
    stop(udid, bundle)
    start(udid, bundle, folder)
    wait_done(folder, "launch")
    for _ in range(rounds):
        sh("xcrun", "simctl", "launch", udid, "com.apple.Preferences")
        time.sleep(1.5)
        start(udid, bundle, folder)
        time.sleep(1.5)
    sh("xcrun", "simctl", "terminate", udid, "com.apple.Preferences", check=False, quiet=True)
    # What talking to the push relay costs the main thread on each return, measured against a relay that is not there.
    notify(udid, "relay")
    wait_done(folder, "relay")
    out = {"scenario": "resume", "box": box,
           "foreground→idle ms": spread(folder, "resume.idle"), "foreground→idle main cpu": spread(folder, "resume.idle", "cpu"),
           "our active handler ms": spread(folder, "phase.active"), "our active handler cpu": spread(folder, "phase.active", "cpu"),
           "our background handler ms": spread(folder, "phase.background"), "our background handler cpu": spread(folder, "phase.background", "cpu"),
           "relay: register, main cpu": spread(folder, "relay.register", "cpu"), "relay: register, ms": spread(folder, "relay.register"),
           "relay: open live link, main cpu": spread(folder, "relay.liveStart", "cpu"), "relay: open live link, ms": spread(folder, "relay.liveStart"),
           "badge count, main cpu": spread(folder, "relay.badge", "cpu"), "badge count, ms": spread(folder, "relay.badge")}
    stop(udid, bundle)
    print(json.dumps(out, indent=1))


def notify(udid, command):
    sh("xcrun", "simctl", "spawn", udid, "notifyutil", "-p", "com.ahmedkhaleel.machbench.launch." + command)


def command_webkill(box):
    udid = boot()
    bundle = install(udid, build())
    folder = fresh(box, box)
    stop(udid, bundle)
    start(udid, bundle, folder)
    wait_done(folder, "launch")
    notify(udid, "webkill")
    wait_done(folder, "webkill", seconds=120)
    out = {"scenario": "webkill", "box": box, "killed→conversation painted ms": spread(folder, "webkill.redrawn"),
           "killed→page ready ms": spread(folder, "webkill.ready"), "killed→noticed ms": spread(folder, "webkill.ready", "noticed"),
           "main cpu": spread(folder, "webkill.ready", "cpu"), "chars drawn": spread(folder, "webkill.redrawn", "chars"),
           "first page load at launch ms": spread(folder, "thread_web_warmup"),
           "error": [line for line in lines(folder) if line.get("metric") == "webkill.error"]}
    stop(udid, bundle)
    print(json.dumps(out, indent=1))


def command_push(box):
    udid = boot()
    bundle = install(udid, build())
    folder = fresh(box, box)
    payload = os.path.join(RUN, "silent.apns")
    with open(payload, "w") as file:
        json.dump({"aps": {"content-available": 1}}, file)
    stop(udid, bundle)
    start(udid, bundle, folder)
    wait_done(folder, "launch")
    for _ in range(10):
        sh("xcrun", "simctl", "push", udid, bundle, payload)
        time.sleep(0.5)
    running = {"handler ms": spread(folder, "push.silent"), "handler main cpu": spread(folder, "push.silent", "cpu")}
    stop(udid, bundle)
    # To an app that is not running: does the system start it, and how much of a launch does that cost?
    os.remove(os.path.join(folder, "bench.jsonl"))
    sh("xcrun", "simctl", "push", udid, bundle, payload)
    time.sleep(4)
    cold = {line["metric"]: {"ms": line["ms"], "cpu": line.get("cpu")} for line in lines(folder)}
    stop(udid, bundle)
    print(json.dumps({"scenario": "push", "box": box, "to the running app": running, "to an app that is not running": cold}, indent=1))


def command_notify(rounds):
    """The notification extension's own code, run in the simulator as a small program (see notify/main.swift)."""
    udid = boot()
    binary = os.path.join(RUN, "notify-bench")
    # NOTIFY_SOURCE=<another NotificationService.swift> measures an older version of the extension with the same harness.
    service = os.environ.get("NOTIFY_SOURCE") or os.path.join(ROOT, "App/NotifyExtension/NotificationService.swift")
    sources = [service] + [os.path.join(ROOT, path) for path in ("App/Shared/AvatarStore.swift", "bench/ios-launch/notify/main.swift")]
    sh("xcrun", "-sdk", "iphonesimulator", "swiftc", "-O", "-D", "BENCH", "-target", "arm64-apple-ios18.0-simulator", *sources, "-o", binary)
    out = {"scenario": "notify"}
    for mode in ("none", "good", "hang"):
        cache = os.path.join(RUN, "notify-avatars-" + mode)
        shutil.rmtree(cache, ignore_errors=True)
        env = dict(os.environ, SIMCTL_CHILD_MACH_AVATAR_DIR=cache, SIMCTL_CHILD_MACH_OFFLINE="1")
        count = 3 if mode == "hang" else rounds
        printed = subprocess.run(["xcrun", "simctl", "spawn", udid, binary, mode, str(count)], env=env, capture_output=True, text=True).stdout
        found = [json.loads(line) for line in printed.splitlines() if line.startswith("{")]
        later = [line for line in found if not line["first"]] or found
        if not found:
            out[mode] = "no answer"
            continue
        out[mode] = {"banner held ms (first push, a cold start)": found[0]["ms"], "banner held ms (later pushes, median)": round(middle([line["ms"] for line in later]), 1),
                     "worst ms": max(line["ms"] for line in found), "cpu ms (median)": round(middle([line["cpu"] for line in later]), 1),
                     "got the picture": f"{sum(1 for line in found if line['picture'])}/{len(found)}"}
    print(json.dumps(out, indent=1))


def command_shots(folder):
    udid = boot()
    bundle = install(udid, build())
    data = fresh("synth", "synth")
    os.makedirs(folder, exist_ok=True)
    for look in ("light", "dark"):
        sh("xcrun", "simctl", "ui", udid, "appearance", look)
        stop(udid, bundle)
        start(udid, bundle, data)
        wait_done(data, "launch")
        time.sleep(1.0)
        sh("xcrun", "simctl", "io", udid, "screenshot", os.path.join(folder, f"first-{look}.png"))
        stop(udid, bundle)
        # Started but held before its first instruction, the app leaves the system's launch screen up to be pictured.
        env = dict(os.environ, SIMCTL_CHILD_MACH_DATA_DIR=data, SIMCTL_CHILD_MACH_OFFLINE="1")
        sh("xcrun", "simctl", "launch", "--wait-for-debugger", udid, bundle, env=env)
        time.sleep(2.5)
        sh("xcrun", "simctl", "io", udid, "screenshot", os.path.join(folder, f"launch-{look}.png"))
        stop(udid, bundle)
    sh("xcrun", "simctl", "ui", udid, "appearance", "light")
    print(folder)


def command_sample(box, out):
    udid = boot()
    bundle = install(udid, build())
    folder = fresh(box, box)
    one_launch(udid, bundle, folder)
    stop(udid, bundle)
    env = dict(os.environ, SIMCTL_CHILD_MACH_DATA_DIR=folder, SIMCTL_CHILD_MACH_OFFLINE="1")
    # By process id, never by name: the installed app has the same name and must not be touched.
    launched = subprocess.run(["xcrun", "simctl", "launch", udid, bundle], env=env, capture_output=True, text=True).stdout
    pid = launched.strip().split(": ")[-1]
    subprocess.run(["sample", pid, "3", "1", "-mayDie", "-file", out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop(udid, bundle)
    print(out)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    what = args[0]
    if what == "launch":
        command_launch(args[1], int(args[2]) if len(args) > 2 else 15)
    elif what == "open":
        command_launch(args[1], int(args[2]) if len(args) > 2 else 15, opening=True)
    elif what == "ab":
        command_ab(args[1], args[2], args[3], int(args[4]) if len(args) > 4 else 15, len(args) > 5 and args[5] == "open")
    elif what == "report":
        command_report(args[1])
    elif what == "resume":
        command_resume(args[1], int(args[2]) if len(args) > 2 else 10)
    elif what == "webkill":
        command_webkill(args[1])
    elif what == "push":
        command_push(args[1])
    elif what == "notify":
        command_notify(int(args[1]) if len(args) > 1 else 10)
    elif what == "shots":
        command_shots(args[1])
    elif what == "sample":
        command_sample(args[1], args[2])
    elif what == "down":
        udid, state = device()
        if state == "Booted":
            sh("xcrun", "simctl", "shutdown", udid)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
