#!/usr/bin/env python3
"""Turns a thread-open bench.jsonl into tables of medians (p90 in brackets). Numbers only."""
import json
import sys
from collections import defaultdict

lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]


def stat(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return "-"
    median, p90 = values[len(values) // 2], values[min(len(values) - 1, len(values) * 9 // 10)]
    return f"{median:.2f} ({p90:.2f})"


def table(title, columns, rows):
    print(f"\n### {title}\n")
    print("| " + " | ".join(columns) + " |")
    print("|" + "---|" * len(columns))
    for row in rows:
        print("| " + " | ".join(str(cell) for cell in row) + " |")


order = ["news20", "news150", "images", "plain1", "thread60", "thread200", "heaviest"]
for metric, end in (("thread_open", ["page_entered", "page_laid_out", "e2e_layout"]), ("thread_open_paint", ["page_entered", "page_laid_out", "page_painted", "e2e_paint"])):
    for unread in (False, True):
        groups = defaultdict(list)
        for line in lines:
            if line["metric"] == metric and line["unread"] == unread:
                groups[line["shape"]].append(line)
        if not groups:
            continue
        fields = ["swift_db", "swift_payload", "swift_regex", "swift_people", "swift_dates", "swift_json", "swift_escape", "swift_eval",
                  "swift_show", "main_free", "page_build", "page_layout"] + end + ["settled", "web_cpu", "renders", "later_bytes", "later_swift_ms", "later_page_ms"]
        rows = []
        for shape in order:
            runs = groups.get(shape)
            if not runs:
                continue
            rows.append([shape, len(runs), runs[0]["messages"], runs[0]["bytes"]] + [stat([run.get(field) for run in runs]) for field in fields])
        what = "painted (window shown)" if metric == "thread_open_paint" else "laid out"
        table(f"Opening a{'n unread' if unread else ' read'} conversation, to {what}: ms, median (p90)", ["shape", "runs", "messages", "payload bytes"] + fields, rows)
        for shape in order:
            for value in sorted({run["dom"] for run in groups.get(shape, []) if "dom" in run}):
                print(f"dom {'unread' if unread else 'read'} {shape}: {value}")

rapid = defaultdict(list)
for line in lines:
    if line["metric"] == "thread_rapid":
        rapid[line["interval"]].append(line)
if rapid:
    fields = ["ms", "press_median", "press_max", "press_total", "lag_median", "lag_max", "sent", "drawn", "page_ms", "bytes"]
    table("Holding j with a conversation open, 30 presses: ms, median (p90). `ms` is last press to its conversation laid out",
          ["ms between presses", "runs"] + fields, [[interval, len(runs)] + [stat([run.get(field) for run in runs]) for field in fields] for interval, runs in sorted(rapid.items())])

memory = [line for line in lines if line["metric"] == "thread_memory"]
if memory:
    table("Web content process memory, MB", ["round", "conversations opened", "idle", "after the opens", "after closing"],
          [[line["round"], line["threads"], line["idle_mb"], line["after_opens_mb"], line["after_close_mb"]] for line in memory])

for name in ("thread_web_ready", "thread_web_warmup"):
    values = [line["ms"] for line in lines if line["metric"] == name]
    if values:
        print(f"\n{name}: {values[0]:.1f} ms" + (" since the process started" if name.endswith("ready") else " from creating the web view to the page saying ready"))
for line in lines:
    if line["metric"] == "thread_verify":
        print(f"classified {line['checked']} messages both ways: {line['rich']} rich, {line['cid']} with cid images, {line['wrong']} differences")
    if line["metric"] == "thread_bench_error":
        print("ERROR:", line.get("what"))
