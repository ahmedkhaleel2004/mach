"""Prints the median and 90th percentile of every number a bench/ios-rest run wrote. Numbers only."""
import json, sys

groups, order = {}, []
for line in open(sys.argv[1]):
    try:
        row = json.loads(line)
    except ValueError:
        continue
    metric = row.pop("metric")
    if metric in ("rest_bench_done", "shot", "shot.type") or metric.startswith("thread_"):
        continue
    if metric not in groups:
        groups[metric] = {}
        order.append(metric)
    for key, value in row.items():
        if isinstance(value, (int, float)) and key != "round":
            groups[metric].setdefault(key, []).append(value)


def stats(values):
    values = sorted(values)
    pick = lambda q: values[min(len(values) - 1, int(q * len(values)))]
    return pick(0.5), pick(0.9), len(values)


for metric in order:
    fields = groups[metric]
    mid, high, count = stats(fields.pop("ms"))
    rest = "  ".join(f"{key}={stats(values)[0]:.4g}" for key, values in sorted(fields.items()))
    print(f"{metric:28s} median {mid:8.2f}  p90 {high:8.2f}  n={count:<3d} {rest}")
