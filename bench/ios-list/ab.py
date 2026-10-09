"""Prints an A/B comparison from the runs `ab.sh` kept: for each metric the median of every round, per side.

A metric is named `metric` (its main number) or `metric:field` (another number on the same line).
"""
import glob, json, os, sys

folder, wanted = sys.argv[1], sys.argv[2:]


def medians(path):
    groups = {}
    for line in open(path):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        metric = row.pop("metric")
        if metric.startswith("list_"):
            continue
        for key, value in row.items():
            if isinstance(value, (int, float)):
                groups.setdefault(metric if key == "ms" else metric + ":" + key, []).append(value)
    # A count that is missing from a line was zero on that line.
    for key, values in groups.items():
        if ":" in key and key.split(":")[1].startswith(("body_", "layer", "views", "mainSQL")):
            values.extend([0] * (len(groups.get(key.split(":")[0], values)) - len(values)))
    return {metric: sorted(values)[len(values) // 2] for metric, values in groups.items()}


sides = {side: [medians(path) for path in sorted(glob.glob(os.path.join(folder, side + "-*.jsonl")))] for side in "AB"}
metrics = wanted or sorted(key for key in sides["A"][0] if ":" not in key)
mid = lambda values: sorted(values)[len(values) // 2]
show = lambda values: " ".join(f"{value:8.3f}" for value in values)
for metric in metrics:
    a = [run[metric] for run in sides["A"] if metric in run]
    b = [run[metric] for run in sides["B"] if metric in run]
    if not a or not b:
        continue
    change = (mid(b) - mid(a)) / mid(a) * 100 if mid(a) else 0
    print(f"{metric:34s} A {show(a)}   B {show(b)}   median {mid(a):.3f} -> {mid(b):.3f} ({change:+.1f}%)  min {min(a):.3f} -> {min(b):.3f}")
