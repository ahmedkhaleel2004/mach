#!/usr/bin/env python3
"""Two builds' benchmark lines side by side: median before, median after, change. Numbers only.

    compare.py <before.jsonl>[,<more>...] <after.jsonl>[,<more>...] [field ...]

Each side may be several files (ab.sh's rounds), pooled. With no fields named, every number both sides have is shown.
"""
import json
import sys
from collections import defaultdict

KEYS = ["shape", "unread", "case", "pass", "open", "round", "interval"]


def load(paths):
    groups = defaultdict(lambda: defaultdict(list))
    for path in paths.split(","):
        for line in open(path):
            if not line.strip():
                continue
            row = json.loads(line)
            key = (row["metric"],) + tuple(str(row[k]) for k in KEYS if k in row)
            for field, value in row.items():
                if field in KEYS or field == "metric":
                    continue
                groups[key][field].append(value)
    return groups


def median(values):
    numbers = sorted(v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool))
    return numbers[len(numbers) // 2] if numbers else None


before, after = load(sys.argv[1]), load(sys.argv[2])
wanted = sys.argv[3:]
print("| metric | field | before | after | change |")
print("|---|---|---|---|---|")
for key in before:
    if key not in after or key[0] in ("thread_bench_done", "thread_bench_all_done", "thread_web_ready", "thread_web_warmup"):
        continue
    for field in sorted(set(before[key]) | set(after[key])):
        if wanted and field not in wanted:
            continue
        old_values, new_values = before[key].get(field, []), after[key].get(field, [])
        old, new = median(old_values), median(new_values)
        if old is None and new is None:
            old_text, new_text = sorted({str(v) for v in old_values}), sorted({str(v) for v in new_values})
            if not wanted and old_text == new_text:
                continue
            print(f"| {' '.join(key)} | {field} | {' / '.join(old_text)} | {' / '.join(new_text)} | {'same' if old_text == new_text else 'DIFFERENT'} |")
            continue
        old, new = old or 0, new or 0
        change = f"{(new - old) / old * 100:+.0f}%" if old else ("" if new == old else "new")
        print(f"| {' '.join(key)} | {field} | {old:g} | {new:g} | {change} |")
