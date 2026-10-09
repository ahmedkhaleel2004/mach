#!/usr/bin/env python3
"""Reads a `sample` report of a launch and prints where the main thread's time went.

    bench/ios-launch/hot.py <sample.txt> [least samples to show, default 10] [deepest level, default 60]
    bench/ios-launch/hot.py <sample.txt> flat [how many]      the functions with the most samples of their own
    bench/ios-launch/hot.py <sample.txt> in <image> [least]   only the frames from one binary (for example Mach), nested
    bench/ios-launch/hot.py <sample.txt> under <regex>...     samples spent inside frames matching each pattern (outermost match only)

DSYM=<Mach.app.dSYM> puts names on the app's own frames (a Release build keeps its names there, not in the app).
One sample is one millisecond. The system's loader (dyld) is one line: in a simulator it loads every system library
by hand, which an iPhone does not do, so its size here says nothing about a phone.
"""
import collections
import glob
import os
import re
import subprocess
import sys

LINE = re.compile(r"^(?P<lead>[\s+!:|]*?)(?P<count>\d+) (?P<name>.+?)(?:  \(in (?P<image>[^)]+)\))?(?: \+ [\d,.]+)?\s*(?:\[0x[0-9a-f,x.]+\])?\s*$")


def main_thread(path):
    rows = []
    inside = False
    with open(path, errors="replace") as file:
        for raw in file:
            line = raw.rstrip("\n")
            if "Thread_" in line and re.match(r"^\s+\d+ Thread_", line):
                if inside:
                    break
                inside = "Main Thread" in line
                continue
            if inside:
                if not line.strip() or line.startswith("Total number"):
                    break
                match = LINE.match(line)
                if match:
                    rows.append((len(match["lead"]), int(match["count"]), match["name"].strip(), match["image"] or ""))
    return rows


UNKNOWN = re.compile(r"^\?\?\?  \(in (?P<image>[^)]+)\)  load address (?P<load>0x[0-9a-f]+) \+ (?P<offset>0x[0-9a-f]+)")


def named(rows):
    """Looks the app's own addresses up in its .dSYM."""
    dsym = os.environ.get("DSYM")
    if not dsym:
        return rows
    wanted = {}
    for _, _, name, _ in rows:
        match = UNKNOWN.match(name)
        if match:
            wanted.setdefault((match["image"], match["load"]), set()).add(match["offset"])
    names = {}
    for (image, load), offsets in wanted.items():
        binary = glob.glob(os.path.join(dsym, "Contents/Resources/DWARF", image))
        if not binary:
            continue
        ordered = sorted(offsets)
        addresses = [hex(int(load, 16) + int(offset, 16)) for offset in ordered]
        out = subprocess.run(["atos", "-o", binary[0], "-l", load] + addresses, capture_output=True, text=True).stdout.splitlines()
        for offset, line in zip(ordered, out):
            names[(image, load, offset)] = re.sub(r" \(in [^)]+\)", "", line)
    result = []
    for lead, count, name, image in rows:
        match = UNKNOWN.match(name)
        if match and (match["image"], match["load"], match["offset"]) in names:
            result.append((lead, count, names[(match["image"], match["load"], match["offset"])], match["image"]))
        else:
            result.append((lead, count, name, image))
    return result


def short(name):
    name = re.sub(r"\[0x[0-9a-f]+\]", "", name)
    return name if len(name) <= 150 else name[:147] + "..."


def tree(rows, least, deepest):
    base = rows[0][0] if rows else 0
    skip_below = None
    for lead, count, name, image in rows:
        level = (lead - base) // 2
        if skip_below is not None:
            if level > skip_below:
                continue
            skip_below = None
        if image in ("dyld", "dyld_sim") and name.startswith("dyld4::") or name == "_dyld_sim_prepare":
            if count >= least and level <= deepest:
                print(f"{' ' * min(level, 70)}{count} (the system loader: loading a library or looking up a symbol)")
            skip_below = level
            continue
        if count < least or level > deepest:
            continue
        print(f"{' ' * min(level, 70)}{count} {short(name)}  [{image}]")


def only(rows, wanted, least):
    """The frames of one binary, each indented under the nearest frame of that binary above it."""
    stack = []
    for lead, count, name, image in rows:
        while stack and stack[-1] >= lead:
            stack.pop()
        if image == wanted or f"(in {wanted})" in name:
            if count >= least:
                print(f"{'  ' * len(stack)}{count} {short(name)}")
            stack.append(lead)


def under(rows, patterns):
    for pattern in patterns:
        wanted = re.compile(pattern)
        total = 0
        inside = None
        for lead, count, name, image in rows:
            if inside is not None and lead > inside:
                continue
            inside = None
            if wanted.search(name + " [" + image + "]"):
                total += count
                inside = lead
        print(f"{total:6d}  {pattern}")


def flat(rows, top):
    """A function's own samples: its count minus its children's."""
    own = collections.Counter()
    for index, (lead, count, name, image) in enumerate(rows):
        children = 0
        for later_lead, later_count, _, _ in rows[index + 1:]:
            if later_lead <= lead:
                break
            if later_lead == lead + 2:
                children += later_count
        if count - children > 0:
            own[(short(name), image)] += count - children
    for (name, image), count in own.most_common(top):
        print(f"{count:6d}  {name}  [{image}]")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    found = named(main_thread(sys.argv[1]))
    if len(sys.argv) > 3 and sys.argv[2] == "in":
        only(found, sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 3)
    elif len(sys.argv) > 3 and sys.argv[2] == "under":
        under(found, sys.argv[3:])
    elif len(sys.argv) > 2 and sys.argv[2] == "flat":
        flat(found, int(sys.argv[3]) if len(sys.argv) > 3 else 40)
    else:
        tree(found, int(sys.argv[2]) if len(sys.argv) > 2 else 10, int(sys.argv[3]) if len(sys.argv) > 3 else 60)
