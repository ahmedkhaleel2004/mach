#!/usr/bin/env python3
"""Prints the results table of bench/results/store-db.md from the four committed result files.

    bench/store-db/table.py > /tmp/table.md
"""
import json
import os

here = os.path.dirname(os.path.abspath(__file__))


def load(name):
    out = {}
    for line in open(os.path.join(here, name)):
        if not line.startswith("{"):
            continue
        row = json.loads(line)
        metric = row.get("metric")
        if metric is None:
            continue
        if "median_ms" in row:
            out[metric] = (row["median_ms"], "ms")
        elif "pages" in row:
            out[metric] = (row["pages"], "pages")
        elif "refreshes" in row:
            out[metric + " (refreshes sent to the app per 50 writes)"] = (row["refreshes"], "")
            out[metric + " (extra CPU per write)"] = (row["extra_cpu_ms_per_write"], "ms")
        elif "seconds" in row and "wal_peak_mb" in row:
            out[metric] = (row["seconds"], "s")
            out[metric + ".wal_peak"] = (row["wal_peak_mb"], "MB")
        elif metric == "storage.file":
            out[metric] = (row["mb"], "MB")
    return out


def cell(value):
    if value is None:
        return "-"
    number, unit = value
    text = f"{number:.0f}" if unit in ("pages", "") else (f"{number:.3f}" if number < 10 else f"{number:.1f}")
    return f"{text} {unit}".strip()


def change(old, new):
    if old is None or new is None or old[0] <= 0:
        return "-"
    return f"{(new[0] - old[0]) / old[0] * 100:+.0f}%"


files = {key: load(f"{kind}-{box}.jsonl") for kind in ("baseline", "final") for box in ("synth", "real") for key in [(kind, box)]}
names = list(files[("final", "synth")].keys())
print("| metric | synth before | synth after | change | real before | real after | change |")
print("|---|---|---|---|---|---|---|")
for name in names:
    sb, sa = files[("baseline", "synth")].get(name), files[("final", "synth")].get(name)
    rb, ra = files[("baseline", "real")].get(name), files[("final", "real")].get(name)
    print(f"| {name} | {cell(sb)} | {cell(sa)} | {change(sb, sa)} | {cell(rb)} | {cell(ra)} | {change(rb, ra)} |")
