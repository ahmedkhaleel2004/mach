#!/usr/bin/env python3
"""Benchmarks for the `lean` frontier on the Mac app: launch time, memory, idle energy, compose.

    bench/lean/lean.py launch  synth|real [runs]      time from process start to the first settled screen
    bench/lean/lean.py keys    synth|real             500 presses of j and 20 list switches, each to a settled screen
    bench/lean/lean.py memory  synth|real             memory of the app and its web helpers at five moments
    bench/lean/lean.py idle    synth|real [seconds]   processor time and wake-ups while nothing happens (default 300 s)
    bench/lean/lean.py compose synth|real             opening, typing, address lookup, saving, replying, sending
    bench/lean/lean.py avatars synth                  memory and scrolling when every sender has a (made-up) picture

Needs: `export MACH_BENCH_DATA=<folder with synth/ and real/>` and the benchmark app (`bench/build.sh mac`; set APP=
to use another build). Every run works on a throwaway copy of the mailbox under build/lean/, offline, on its own
command channel, in the background, and stops the app it started by process id. Prints one JSON object per line.
For the real mailbox only numbers are printed, and no conversation is ever opened: the conversation view loads a
mail's remote pictures from the network even when the app is offline, and a benchmark must not do that to real
mail. Steps that need an open conversation run on synth only (its pictures point at hosts that do not exist).
"""
import ctypes
import json
import os
import re
import sqlite3
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHANNEL = "com.ahmedkhaleel.machbench.lean"
APP = os.environ.get("APP") or os.path.join(ROOT, "build/dd-mac/Build/Products/Release/Mach.app")
EXE = os.path.join(APP, "Contents/MacOS/Mach")
WORK = os.path.join(ROOT, "build/lean")
POST = os.path.join(WORK, "post")

libc = ctypes.CDLL(None)
libc.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(_timebase))


class RUsage(ctypes.Structure):
    # rusage_info_v2 from <sys/resource.h>
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size", "resident_size",
        "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time", "child_system_time",
        "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins", "child_elapsed_abstime", "diskio_bytesread",
        "diskio_byteswritten")]


def usage(pid):
    """Processor time (ms), wake-ups and memory (MB) the system has charged to a process so far."""
    info = RUsage()
    if libc.proc_pid_rusage(pid, 2, ctypes.byref(info)) != 0:
        return None
    ticks = (info.user_time + info.system_time) * _timebase.numer / _timebase.denom
    return {"cpu_ms": ticks / 1e6, "idle_wakeups": info.pkg_idle_wkups, "interrupt_wakeups": info.interrupt_wkups,
            "footprint_mb": info.phys_footprint / 1048576, "resident_mb": info.resident_size / 1048576,
            "disk_written_kb": info.diskio_byteswritten / 1024}


def helpers(pid):
    """The WebKit processes working for this app, found by which app the system holds responsible for them."""
    found = {}
    listing = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and "com.apple.WebKit." in parts[1] and libc.responsibility_get_pid_responsible_for_pid(int(parts[0])) == pid:
            found[int(parts[0])] = parts[1].rsplit("com.apple.WebKit.", 1)[1]
    return found


class AppGone(Exception):
    """The app under test stopped running in the middle of a benchmark (something else on this Mac ended it)."""


pending = []


def emit(metric, **fields):
    # Held back until the whole benchmark has finished, so a run that has to start over leaves nothing half-told.
    pending.append(json.dumps({"metric": metric, **fields}, sort_keys=True))


class Run:
    """One copy of the app on one throwaway copy of a mailbox."""

    def __init__(self, mailbox, name):
        if not os.path.exists(EXE):
            sys.exit(f"no benchmark app at {APP}: run bench/build.sh mac")
        os.makedirs(WORK, mode=0o700, exist_ok=True)
        if not os.path.exists(POST) or os.path.getmtime(POST) < os.path.getmtime(os.path.join(ROOT, "bench/lean/post.swift")):
            subprocess.run(["swiftc", "-O", "-o", POST, os.path.join(ROOT, "bench/lean/post.swift")], check=True)
        self.mailbox = mailbox
        self.dir = os.path.join(WORK, f"{name}-{mailbox}")
        os.umask(0o077)
        subprocess.run([os.path.join(ROOT, "bench/data.sh"), "fresh", mailbox, self.dir], check=True)
        # Its own channel, so two benchmarks running at once never hear each other's commands.
        self.channel = f"{CHANNEL}.{name}-{mailbox}"
        self.results = os.path.join(self.dir, "bench.jsonl")
        self.read = 0
        self.unread = []
        self.pid = None

    def start(self, **environment):
        before = set(self._pids())
        extra = [part for key, value in environment.items() for part in ("--env", f"{key}={value}")]
        subprocess.run(["open", "-g", "-n", APP, "--env", f"MACH_DATA_DIR={self.dir}", "--env", "MACH_OFFLINE=1", "--env", f"MACH_DEBUG_CHANNEL={self.channel}"] + extra, check=True)
        deadline = time.time() + 30
        while time.time() < deadline:
            new = [pid for pid in self._pids() if pid not in before]
            if new:
                self.pid = new[0]
                return self
            time.sleep(0.05)
        sys.exit("the app did not start")

    def _pids(self):
        # Only processes running this exact file inside this checkout's build folder.
        out = subprocess.run(["pgrep", "-f", "^" + re.escape(EXE)], capture_output=True, text=True).stdout
        return [int(line) for line in out.split()]

    def stop(self):
        if self.pid:
            subprocess.run(["kill", str(self.pid)])
            for _ in range(100):
                if subprocess.run(["kill", "-0", str(self.pid)], capture_output=True).returncode != 0:
                    break
                time.sleep(0.05)
            self.pid = None

    def send(self, command):
        subprocess.run([POST, self.channel, command], check=True)

    def lines(self):
        """New lines in the app's results file since the last look."""
        if not os.path.exists(self.results):
            return []
        with open(self.results) as handle:
            handle.seek(self.read)
            text = handle.read()
            complete = text.rfind("\n") + 1
            self.read += len(text[:complete].encode())
        return [json.loads(line) for line in text[:complete].splitlines() if line.strip()]

    def wait(self, metric, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.unread += self.lines()
            for index, line in enumerate(self.unread):
                if line.get("metric") == metric:
                    del self.unread[:index + 1]
                    return line
            if self.pid and subprocess.run(["kill", "-0", str(self.pid)], capture_output=True).returncode != 0:
                raise AppGone(metric)
            time.sleep(0.05)
        self.stop()
        sys.exit(f"timed out waiting for {metric}")

    def do(self, command, metric, timeout=180):
        self.send(command)
        return self.wait(metric, timeout)

    def settle(self):
        self.wait("launch.settled", 60)
        self.do("lean:mark:ready", "mark.ready")

    def query(self, sql, *arguments):
        with sqlite3.connect(f"file:{self.dir}/mail.sqlite?mode=ro", uri=True) as db:
            return db.execute(sql, arguments).fetchall()


def spread(values):
    values = sorted(values)
    return {"median": round(statistics.median(values), 2), "p90": round(values[min(len(values) - 1, len(values) * 9 // 10)], 2), "min": round(values[0], 2), "n": len(values)}


def launch(mailbox, runs=10):
    finished, settled = [], []
    for _ in range(runs):
        run = Run(mailbox, "launch").start()
        try:
            deadline = time.time() + 60
            seen = {}
            while "launch.settled" not in seen and time.time() < deadline:
                for line in run.lines():
                    seen[line["metric"]] = line["ms"]
                time.sleep(0.05)
            if "launch.settled" in seen:
                finished.append(seen["launch.did_finish"])
                settled.append(seen["launch.settled"])
        finally:
            run.stop()
        time.sleep(0.5)
    emit("launch.did_finish_ms", mailbox=mailbox, **spread(finished))
    emit("launch.settled_ms", mailbox=mailbox, **spread(settled))


def keys(mailbox):
    """500 presses of j and 20 list switches: the time from each to the screen having settled."""
    run = Run(mailbox, "keys").start()
    try:
        run.settle()
        show(run, run.do("lean:j:500", "lean.key_j"))
        show(run, run.do("lean:lists:20", "lean.switch_list"))
    finally:
        run.stop()


def png(side, seed):
    """A made-up square picture: blocks of colour, a few KB like the real ones."""
    import random
    import struct
    import zlib
    rng = random.Random(seed)
    base = [rng.randrange(256) for _ in range(3)]
    rows = bytearray()
    for y in range(side):
        rows.append(0)
        for x in range(side):
            for channel in range(3):
                rows.append((base[channel] + (x // 16) * 9 * (channel + 1) + (y // 16) * 7) % 256)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")


def avatars(mailbox="synth"):
    """Memory and scrolling when every sender has a picture. Synth only: the pictures are made up here and kept in
    the run's own folder (MACH_AVATAR_DIR), never in the real picture cache."""
    import hashlib
    if mailbox != "synth":
        sys.exit("avatars runs on synth only")
    run = Run(mailbox, "avatars")
    folder = os.path.join(run.dir, "avatars")
    os.makedirs(folder)
    emails = [row[0] for row in run.query("""SELECT DISTINCT t.avatarEmail FROM thread_label l JOIN thread t ON t.accountId = l.accountId AND t.id = l.threadId
                                             WHERE l.labelId = 'INBOX' AND t.avatarEmail != '' ORDER BY l.sortDate DESC LIMIT 900""")]
    for index, email in enumerate(emails):
        # The sizes real ones come in: mostly 128 (site icons), some 192 (profile pictures).
        with open(os.path.join(folder, hashlib.sha256(email.lower().encode()).hexdigest()[:32]), "wb") as handle:
            handle.write(png(192 if index % 5 == 0 else 128, index))
    run.start(MACH_AVATAR_DIR=folder)
    try:
        run.settle()
        time.sleep(5)
        snapshot(run, "pictures: just launched")
        show(run, run.do("lean:j:500", "lean.key_j"), pictures=len(emails))
        time.sleep(3)
        snapshot(run, "pictures: after 500 j presses")
        show(run, run.do("lean:j:500", "lean.key_j"), pictures=len(emails), second_pass=True)
        time.sleep(3)
        snapshot(run, "pictures: after 1000 j presses", True)
    finally:
        run.stop()


def snapshot(run, moment, keep_detail=False):
    app = usage(run.pid)
    if app is None:
        raise AppGone(moment)
    web = {name: 0.0 for name in ("WebContent", "GPU", "Networking")}
    for pid, name in helpers(run.pid).items():
        used = usage(pid)
        if used:
            web[name] = web.get(name, 0) + used["footprint_mb"]
    total = app["footprint_mb"] + sum(web.values())
    emit("memory", mailbox=run.mailbox, moment=moment, app_mb=round(app["footprint_mb"], 1), app_resident_mb=round(app["resident_mb"], 1),
         web_content_mb=round(web["WebContent"], 1), web_gpu_mb=round(web["GPU"], 1), web_network_mb=round(web["Networking"], 1), total_mb=round(total, 1))
    if keep_detail:
        # Where the memory is, for reading by hand. Kept under build/ only: it can name things from the mailbox.
        for tool, arguments in (("footprint", [str(run.pid)]), ("vmmap", ["--summary", str(run.pid)])):
            out = subprocess.run([tool] + arguments, capture_output=True, text=True).stdout
            with open(os.path.join(run.dir, f"{tool}-{moment.replace(' ', '-')}.txt"), "w") as handle:
                handle.write(out)


def memory(mailbox):
    run = Run(mailbox, "memory").start()
    try:
        run.settle()
        time.sleep(3)
        snapshot(run, "just launched", True)
        time.sleep(60)
        snapshot(run, "after 60 s idle")
        run.do("lean:j:500", "lean.key_j")
        time.sleep(2)
        snapshot(run, "after 500 j presses", True)
        if mailbox == "synth":
            run.do("lean:open:30", "lean.open_close")
            time.sleep(2)
            snapshot(run, "after opening 30 conversations", True)
        run.do("lean:lists:20", "lean.switch_list")
        time.sleep(2)
        snapshot(run, "after switching lists 20 times", True)
    finally:
        run.stop()


def idle(mailbox, seconds=300):
    run = Run(mailbox, "idle").start()
    try:
        run.settle()
        # Open and close one conversation first, so the web view has been used the way it is in real life.
        if mailbox == "synth":
            run.do("lean:open:1", "lean.open_close")
        time.sleep(20)
        pids = {run.pid: "app", **helpers(run.pid)}
        before = {pid: usage(pid) for pid in pids}
        time.sleep(seconds)
        if usage(run.pid) is None:
            raise AppGone("the idle period")
        total_cpu, total_wake = 0.0, 0
        for pid, name in pids.items():
            now = usage(pid)
            if not now or not before[pid]:
                continue
            cpu = now["cpu_ms"] - before[pid]["cpu_ms"]
            wake = now["idle_wakeups"] - before[pid]["idle_wakeups"]
            interrupts = now["interrupt_wakeups"] - before[pid]["interrupt_wakeups"]
            total_cpu += cpu
            total_wake += wake
            emit("idle", mailbox=mailbox, process=name, seconds=seconds, cpu_ms=round(cpu, 1), cpu_ms_per_minute=round(cpu * 60 / seconds, 2),
                 idle_wakeups=wake, idle_wakeups_per_minute=round(wake * 60 / seconds, 1), interrupt_wakeups=interrupts,
                 disk_written_kb=round(now["disk_written_kb"] - before[pid]["disk_written_kb"], 1))
        emit("idle.total", mailbox=mailbox, seconds=seconds, cpu_ms_per_minute=round(total_cpu * 60 / seconds, 2), idle_wakeups_per_minute=round(total_wake * 60 / seconds, 1))
    finally:
        run.stop()


def show(run, line, **extra):
    fields = {key: value for key, value in line.items() if key not in ("metric", "ms")}
    emit(line["metric"], mailbox=run.mailbox, ms=line["ms"], **fields, **extra)


def compose(mailbox):
    run = Run(mailbox, "compose").start()
    try:
        run.settle()
        # A new message over the inbox list.
        show(run, run.do("lean:compose:20", "compose.open"))
        run.send("c")
        time.sleep(0.5)
        show(run, run.do("lean:type:200", "compose.type_char"), case="new message")
        show(run, run.do("lean:save:30", "compose.save_on_main"), case="new message")
        show(run, run.do("lean:savebusy:5", "compose.save_while_db_busy"))
        # Type the start of the name of the most-used contact, so the lookup has something to find.
        account = run.query("SELECT id FROM account ORDER BY sortOrder, id LIMIT 1")[0][0]
        name = (run.query("SELECT lower(name) FROM contact WHERE accountId = ? AND length(name) >= 6 ORDER BY uses DESC LIMIT 1", account) or [("example",)])[0][0][:8]
        show(run, run.do(f"lean:to:{name}", "compose.type_to"))
        show(run, run.do(f"lean:contacts:{name}", "compose.contacts_lookup"), contacts=run.query("SELECT count(*) FROM contact")[0][0])
        run.send("lean:discard")
        time.sleep(0.3)

        # Replies: to the conversation with the most messages, and to the single biggest message, among the first
        # 300 of the inbox (what is on screen), first with the cursor on it in the list, then with it open.
        inbox = """SELECT t.accountId, t.id FROM thread_label l JOIN thread t ON t.accountId = l.accountId AND t.id = l.threadId
                   WHERE l.labelId = 'INBOX' ORDER BY l.sortDate DESC LIMIT 300"""
        longest = run.query(f"""SELECT x.accountId, x.id, count(*), sum(length(coalesce(m.bodyHTML, m.bodyText, ''))) FROM ({inbox}) x
                               JOIN message m ON m.accountId = x.accountId AND m.threadId = x.id GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 1""")[0]
        biggest = run.query(f"""SELECT x.accountId, x.id, count(*), max(length(coalesce(m.bodyHTML, m.bodyText, ''))) FROM ({inbox}) x
                               JOIN message m ON m.accountId = x.accountId AND m.threadId = x.id GROUP BY 1, 2 ORDER BY 4 DESC LIMIT 1""")[0]
        for case, (account, thread, messages, size) in (("longest conversation", longest), ("biggest message", biggest)):
            about = {"case": case, "messages": messages, "kb": round(size / 1024)}
            found = run.do(f"lean:cursor:{thread}", "lean.cursor")
            if found.get("found"):
                show(run, run.do("lean:replystart:10", "compose.reply_start_call"), where="cursor in list", **about)
                show(run, run.do("lean:reply:10", "compose.reply_open"), where="cursor in list", **about)
                run.wait("compose.reply_quoted_bytes")
                run.send("r")
                time.sleep(0.5)
                show(run, run.do("lean:type:200", "compose.type_char"), where="cursor in list", **about)
                show(run, run.do("lean:save:30", "compose.save_on_main"), **about)
                if case == "biggest message":
                    show(run, run.do("lean:send", "compose.send"), where="cursor in list", **about)
                else:
                    run.send("lean:discard")
                time.sleep(0.5)
            if mailbox != "synth":
                continue
            run.send(f"lean:goto:{account}|{thread}")
            time.sleep(1.5)
            show(run, run.do("lean:replystart:10", "compose.reply_start_call"), where="conversation open", **about)
            show(run, run.do("lean:reply:10", "compose.reply_open"), where="conversation open", **about)
            run.wait("compose.reply_quoted_bytes")
            run.send("r")
            time.sleep(0.5)
            show(run, run.do("lean:type:200", "compose.type_char"), where="conversation open", **about)
            show(run, run.do("lean:save:30", "compose.save_on_main"), **about)
            run.send("lean:discard")
            time.sleep(0.5)
            run.send("lean:close")
            time.sleep(0.5)
    finally:
        run.stop()


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[2] not in ("synth", "real") or sys.argv[1] not in ("launch", "keys", "memory", "idle", "compose", "avatars"):
        sys.exit(__doc__)
    if not os.environ.get("MACH_BENCH_DATA"):
        sys.exit("set MACH_BENCH_DATA to the folder holding synth/ and real/")
    extra = [int(value) for value in sys.argv[3:]]
    for attempt in range(4):
        pending.clear()
        try:
            {"launch": launch, "keys": keys, "memory": memory, "idle": idle, "compose": compose, "avatars": avatars}[sys.argv[1]](sys.argv[2], *extra)
            print("\n".join(pending), flush=True)
            break
        except AppGone as gone:
            print(f"the app stopped running while waiting for {gone}; starting this benchmark again", file=sys.stderr)
    else:
        sys.exit("the app kept disappearing; is something else on this Mac stopping it?")
