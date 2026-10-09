#!/usr/bin/env python3
"""Prints one or two result files from run.py --json side by side: show.py before.json [after.json]"""
import json, sys

before = json.load(open(sys.argv[1]))
after = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else None
for key in sorted(before):
    a = before[key]
    line = f"{key:26} {a['median']:9.2f} p90 {a['p90']:8.2f} busy {a.get('busy', '-')!s:>8} applies {a.get('applies', '-')!s:>4} over16 {a.get('over16', '-')!s:>4}"
    if after and key in after:
        b = after[key]
        change = (b['median'] - a['median']) / a['median'] * 100 if a['median'] else 0
        line += f" | {b['median']:9.2f} p90 {b['p90']:8.2f} busy {b.get('busy', '-')!s:>8} applies {b.get('applies', '-')!s:>4} over16 {b.get('over16', '-')!s:>4}  {change:+6.1f}%"
    print(line)
