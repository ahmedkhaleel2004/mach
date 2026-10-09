#!/usr/bin/env python3
"""Turns the iPhone reading benchmarks' lines in a bench.jsonl into tables: median (p90). Numbers only.

    report.py <bench.jsonl> [<other bench.jsonl> ...]     several files are pooled (ab.sh passes each build's runs)
"""
import json
import sys
from collections import defaultdict

lines = []
for path in sys.argv[1:]:
    lines += [json.loads(line) for line in open(path) if line.strip()]


def stat(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return "-"
    median, p90 = values[len(values) // 2], values[min(len(values) - 1, len(values) * 9 // 10)]
    if median == p90:
        return f"{median:g}"
    return f"{median:.2f} ({p90:.2f})"


def table(title, metric, keys, fields):
    groups = defaultdict(list)
    for line in lines:
        if line["metric"] == metric:
            groups[tuple(str(line.get(key, "")) for key in keys)].append(line)
    if not groups:
        return
    names = sorted({field for runs in groups.values() for run in runs for field in run if field.startswith("n_") or field.startswith("again_n_")})
    columns = fields + names
    print(f"\n### {title}\n")
    print("| " + " | ".join(keys + ["runs"] + columns) + " |")
    print("|" + "---|" * (len(keys) + 1 + len(columns)))
    for group, runs in groups.items():
        cells = []
        for field in columns:
            values = [run.get(field, 0 if field.startswith(("n_", "again_n_")) else None) for run in runs]
            texts = sorted({str(v) for v in values if isinstance(v, str)})
            cells.append(" / ".join(texts) if texts else stat(values))
        print("| " + " | ".join(list(group) + [str(len(runs))] + cells) + " |")


table("The first frame of each shape: sideways overflow in points and the shrink given, at first layout and a second later", "thread_fit",
      ["shape"], ["over_first", "zoom_first", "over_later", "zoom_later", "ms", "dom"])
table("Collapsed messages built in the background after opening (ms is the page process's processor time until it stops)", "thread_prepare",
      ["shape"], ["messages", "built", "built_at_paint", "built_by_ms", "ms", "web_cpu_500ms", "page_layout", "page_painted", "page_worst_frame",
                  "page_long_frames", "page_lost_ms", "web_mb_before", "web_mb_after", "expand_near_ms", "expand_far_ms"])
table("Scrolling 48 points a frame, top to bottom (ms is the page process's processor time for the whole pass)", "thread_scroll",
      ["shape", "pass"], ["steps", "page_height", "ms", "web_cpu_per_frame", "main_cpu_per_frame", "page_frames", "page_usual_frame", "page_worst_frame",
                          "page_long_frames", "page_lost_ms", "web_mb"])
table("Back swipe, dragging: per frame (n_ columns: how many times each view drew itself in 30 frames)", "thread_back_drag",
      ["case"], ["main_cpu_per_frame", "web_cpu_per_frame", "worst_frame"])
table("Back swipe, letting go: ms from the lift to the list (n_ columns: views drawn)", "thread_back_slide", ["case"], ["ms", "main_cpu", "frames", "worst_frame"])
table("An idle frame's main-thread time, the floor under the per-frame numbers", "thread_back_idle_frame", [], ["ms"])
table("Archive with a conversation open: ms to the next one laid out", "thread_next", [], ["ms", "main_cpu", "call", "page_layout", "bytes", "messages"])
table("The page's process killed: ms until the conversation is laid out again", "thread_reclaim",
      ["shape"], ["ms", "noticed", "page_ready", "page_layout", "painted", "state_before", "state_after", "web_mb"])
table("The app's own picture addresses (n_: requests during the open; again_n_: requests when each is asked for once more)", "thread_pictures",
      ["shape", "open"], ["addresses", "cid_ms", "avatar_ms", "ms"])
table("Page process memory, MB, after opening the 50 largest newsletters", "thread_heavy", ["round"], ["opens", "idle_mb", "after_opens_mb", "after_close_mb", "later_mb"])
table("Stops for looking inside the page's process (ms is its process id)", "thread_hold", ["at"], ["web_mb"])
