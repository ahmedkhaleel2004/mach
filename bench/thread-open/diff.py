#!/usr/bin/env python3
"""Puts two saved thread-open tables (report.py output) side by side: diff.py <before.md> <after.md> [column ...]"""
import sys


def tables(path):
    found, title, header = {}, None, None
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("### "):
            title, header = line[4:].split(":")[0], None
        elif line.startswith("| ") and title:
            cells = [cell.strip() for cell in line.strip("|").split("|")]
            if header is None:
                header = cells
            else:
                found[(title, cells[0])] = dict(zip(header, cells))
        elif line.startswith("dom "):
            name, value = line.split(": ", 1)
            found[("dom", name)] = {"dom": value}
    return found


before, after = tables(sys.argv[1]), tables(sys.argv[2])
wanted = sys.argv[3:] or ["swift_show", "page_laid_out", "page_painted", "later_bytes", "later_page_ms", "settled", "ms", "press_median", "lag_max", "after the opens", "dom"]
for key in before:
    if key not in after:
        continue
    for column in wanted:
        old, new = before[key].get(column), after[key].get(column)
        if old is None or new is None:
            continue
        change = ""
        try:
            a, b = float(old.split()[0]), float(new.split()[0])
            change = f"{(b - a) / a * 100:+.0f}%" if a else ""
        except ValueError:
            change = "same" if old == new else "DIFFERENT"
        print(f"| {key[0]} | {key[1]} | {column} | {old} | {new} | {change} |")
