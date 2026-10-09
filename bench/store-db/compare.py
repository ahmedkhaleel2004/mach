#!/usr/bin/env python3
"""Compares two result files written by bench/store-db/run.sh: prints every metric with its change.

    bench/store-db/compare.py bench/store-db/baseline-synth.jsonl build/store-db/synth-run.jsonl [--md]
"""
import json
import sys


def load(path):
    out = {}
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"):
            continue
        row = json.loads(line)
        if "metric" not in row:
            continue
        for key in ("median_ms", "pages", "mb", "seconds", "extra_cpu_ms_per_write", "wal_peak_mb", "ms"):
            if key in row:
                name = row["metric"] if key in ("median_ms", "pages", "mb", "ms") else row["metric"] + "." + key
                out[name] = (row[key], row.get("p90_ms"), key, row.get("min_ms"))
    return out


before, after = load(sys.argv[1]), load(sys.argv[2])
markdown = "--md" in sys.argv
for name, (old, old_p90, key, old_min) in before.items():
    if name not in after:
        continue
    new, new_p90, _, new_min = after[name]
    change = (new - old) / old * 100 if old else 0.0
    unit = {"median_ms": "ms", "pages": "pages", "mb": "MB", "seconds": "s", "ms": "ms"}.get(key, "ms")
    if markdown:
        p90 = f" (p90 {old_p90:.2f} → {new_p90:.2f})" if old_p90 is not None and new_p90 is not None else ""
        print(f"| {name} | {old:.3f} {unit} | {new:.3f} {unit} | {change:+.0f}%{p90} |")
    else:
        # The fastest run is the steadiest number on a busy machine, so it is shown next to the median.
        fastest = f"   min {old_min:10.3f} {new_min:10.3f} {(new_min - old_min) / old_min * 100 if old_min else 0:+7.1f}%" if old_min is not None and new_min is not None else ""
        print(f"{name:34s} {old:10.3f} {new:10.3f} {unit:5s} {change:+7.1f}%{fastest}")
