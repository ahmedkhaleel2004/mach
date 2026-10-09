"""Prints before and after side by side from two folders of runs (as kept by pair.sh): the median of every number.

    python3 bench/ios-list/compare.py <before folder> <after folder> <run name, e.g. synth-invalidate> [field ...]

With no fields, the counts that matter for the list are shown: rows rebuilt, layers drawn and made, layout passes,
SQL on the main thread, and the main number (processor time, in ms).
"""
import json, os, sys

before, after, name = sys.argv[1], sys.argv[2], sys.argv[3]
wanted = sys.argv[4:] or ["ms", "body_SwipeRow", "body_CompactRow", "body_AvatarView", "body_PhoneRoot", "body_ListRows", "layerDraws", "layersMade", "layerLayouts", "mainSQL"]
COUNTS = ("body_", "layer", "views", "mainSQL", "made_", "drawn_")
short = {"body_SwipeRow": "SwipeRow", "body_CompactRow": "CompactRow", "body_AvatarView": "Avatar", "body_PhoneRoot": "PhoneRoot", "body_ListRows": "ListRows", "ms": "cpu ms"}


def medians(path):
    groups, order = {}, []
    for line in open(path):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        metric = row.pop("metric")
        if metric.startswith("list_") or metric.startswith("thread_"):
            continue
        if metric not in groups:
            groups[metric] = {}
            order.append(metric)
        for key, value in row.items():
            if isinstance(value, (int, float)):
                groups[metric].setdefault(key, []).append(value)
    counts = {metric: len(fields.get("ms", [])) for metric, fields in groups.items()}
    # A count that is missing from a line was zero on that line.
    for metric, fields in groups.items():
        for key, values in fields.items():
            if key.startswith(COUNTS):
                values.extend([0] * (counts[metric] - len(values)))
    return order, {metric: {key: sorted(values)[len(values) // 2] for key, values in fields.items()} for metric, fields in groups.items()}, counts


order, a, counts = medians(os.path.join(before, name + ".jsonl"))
_, b, _ = medians(os.path.join(after, name + ".jsonl"))
print(f"{'':28s}" + "".join(f"{short.get(field, field):>16s}" for field in wanted))
for metric in order:
    cells = []
    for field in wanted:
        # A count that is not on a line was zero.
        x, y = a[metric].get(field, 0), b.get(metric, {}).get(field, 0)
        cells.append(f"{x:.3g} > {y:.3g}".rjust(16))
    print(f"{metric:28s}" + "".join(cells) + f"   n={counts[metric]}")
