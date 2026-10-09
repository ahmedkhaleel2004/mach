"""Prints the median (and 90th percentile) of every number the iPhone list benchmark wrote. Numbers only.

    python3 bench/ios-list/summary.py <folder of .jsonl> [scenario ...]
"""
import json, os, sys

folder, names = sys.argv[1], sys.argv[2:]
if not names:
    names = sorted(name[:-6] for name in os.listdir(folder) if name.endswith(".jsonl"))


def pick(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


for name in names:
    path = os.path.join(folder, name + ".jsonl")
    if not os.path.exists(path):
        continue
    groups, order = {}, []
    for line in open(path):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        metric = row.pop("metric")
        if metric.startswith("list_") or "launch" in metric:
            continue
        if metric == "lab":
            metric = "lab." + str(row.pop("variant", "?"))
        if metric not in groups:
            groups[metric] = {}
            order.append(metric)
        for key, value in row.items():
            if isinstance(value, (int, float)) and key != "round":
                groups[metric].setdefault(key, []).append(value)
    print(f"== {name} ({os.path.basename(folder)})")
    for metric in order:
        fields = groups[metric]
        main = fields.pop("ms", [0])
        # A count that is missing from a line was zero on that line.
        for key, values in fields.items():
            if key.startswith(("body_", "layer", "views", "mainSQL", "made_", "drawn_")):
                values.extend([0] * (len(main) - len(values)))
        rest = "  ".join(f"{key}={pick(values, 0.5):g}" for key, values in sorted(fields.items()))
        print(f"{metric:26s} median {pick(main, 0.5):9.3f}  p90 {pick(main, 0.9):9.3f}  n={len(main):<3d} {rest}")
