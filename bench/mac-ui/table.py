#!/usr/bin/env python3
"""Turns two `run.py all --against <baseline app> --json` files (synth, real) into the markdown table in bench/results/mac-ui.md.

    bench/mac-ui/table.py synth.json real.json
"""
import json, sys

NAMES = [
    ("launch.model", "Launch: process start to the model holding rows", "median"),
    ("launch.firstFrame", "Launch: process start to first list frame handed to the screen (fresh copy of the mailbox)", "median"),
    ("relaunch.firstFrame", "Launch again on the same copy (database in memory)", "median"),
    ("cursor.inview.j", "j, row already in view: main thread until idle", "busy"),
    ("cursor.j.300", "j held down, 300 rows (scrolls a row a press): until idle", "busy"),
    ("cursor.j.1000", "j held down, 1,000 rows: until idle", "busy"),
    ("cursor.j.3000", "j held down, 3,000 rows: until idle", "busy"),
    ("cursor.k.3000", "k held down, 3,000 rows: until idle", "busy"),
    ("cursor.j.3000deep", "j held down from row 1,400 of 3,000: until idle", "busy"),
    ("cursor.page.3000", "Page Down (20 rows), 3,000 rows: until idle", "busy"),
    ("scroll.frame", "Scrolling the list, per frame (mix of 10 rows and 1 row a frame): until idle", "busy"),
    ("switch.go.all", "g a (All Mail): key to first frame", "median"),
    ("switch.go.sent", "g t (Sent): key to first frame", "median"),
    ("switch.go.inbox", "g i (Inbox): key to first frame", "median"),
    ("switch.account.one", "Ctrl 1 (one account): key to first frame", "median"),
    ("switch.account.all", "Ctrl 0 (All Inboxes): key to first frame", "median"),
    ("switch.tab", "Tab (split inbox halves): key to first frame", "median"),
    ("act.done", "e (Mark Done): key to row gone and cursor moved", "median"),
    ("act.done", "e: main thread until idle, database echo included", "busy"),
    ("act.done.open", "e with a conversation open (next one shown): key to frame", "median"),
    ("act.done50", "e with 50 rows ticked: key to frame", "median"),
    ("act.star", "s (star): key to frame", "median"),
    ("act.star", "s: until idle", "busy"),
    ("act.unread", "Shift U: key to frame", "median"),
    ("act.undo", "z (undo one): until idle", "busy"),
    ("act.undo50", "z (undo 50): until idle", "busy"),
    ("act.undo50", "z (undo 50): times the list was set again", "applies"),
    ("churn.write", "A write to mail that is not in the list: main thread per write", "median"),
    ("palette.open", "Cmd K: key to frame", "median"),
    ("palette.keystroke", "Command bar, per typed letter", "median"),
    ("search.keystroke", "Search, main thread per typed letter", "median"),
    ("search.shown", "Search, first letter to results for the whole text (letters a few ms apart)", "median"),
]


def cell(data, metric, field):
    old, new = data["against"].get(metric), data["now"].get(metric)
    if not old or not new or field not in old or field not in new:
        return "–", "–", "–"
    a, b = old[field], new[field]
    change = f"{(b - a) / a * 100:+.0f}%" if a else "–"
    return f"{a:.1f}", f"{b:.1f}", change


synth, real = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
print("| Metric (ms unless said) | synth before | synth after | change | real before | real after | change |")
print("|---|---:|---:|---:|---:|---:|---:|")
for metric, title, field in NAMES:
    print("| " + " | ".join((f"{title} `{metric}`",) + cell(synth, metric, field) + cell(real, metric, field)) + " |")
