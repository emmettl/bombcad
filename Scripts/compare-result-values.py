"""Two builds' results set side by side: how far apart, not only whether the same to the bit.

    python3 Scripts/compare-result-values.py old.log new.log [--dumps old-folder new-folder]

Each log holds blastbench's `--values` lines (`values <label>: key=value ...`, from `digest`,
`snapshot`, `throughput` or `structure` run with `--values`). For every label in both, each value
is printed old and new with their relative difference. With `--dumps`, the folders written by
`--values-dump` are compared element by element: elements whose flag (active, failed, bare),
cracking or bar yield differs, with the damage they had in each build (an element near its
threshold in both is a chaotic flip, not a different outcome), and the nodes' displacements as a
share of their largest. Written for emmettl/bombcad-work#95, whose split element pass moves
results at the rounding level.
"""

import argparse
import json
import math
from pathlib import Path
import re
import sys

LINE = re.compile(r"^values (?P<label>.+?): (?P<rest>.*)$")


def read_values(path):
    values = {}
    for line in Path(path).read_text(errors="replace").splitlines():
        match = LINE.match(line.strip())
        if not match:
            continue
        pairs = {}
        for item in match.group("rest").split():
            if "=" in item:
                key, value = item.split("=", 1)
                try:
                    pairs[key] = float(value)
                except ValueError:
                    pass
        values.setdefault(match.group("label"), {}).update(pairs)
    return values


def relative(old, new):
    if old == new:
        return 0.0
    scale = max(abs(old), abs(new))
    return abs(new - old) / scale if scale > 0 else 0.0


def compare_lines(old, new, out):
    worst = []
    for label in old:
        if label not in new:
            print(f"{label}: only in the old log", file=out)
            continue
        print(f"{label}:", file=out)
        for key, value in old[label].items():
            if key not in new[label]:
                continue
            other = new[label][key]
            share = relative(value, other)
            mark = "" if share == 0 else f"  rel {share:.2e}"
            print(f"  {key:16s} {value:<16.9g} {other:<16.9g}{mark}", file=out)
            worst.append((share, label, key))
    for label in new:
        if label not in old:
            print(f"{label}: only in the new log", file=out)
    return worst


def compare_dump(old_path, new_path, out):
    old = json.loads(Path(old_path).read_text())
    new = json.loads(Path(new_path).read_text())
    print(f"{Path(old_path).stem}:", file=out)
    if len(old["flags"]) != len(new["flags"]):
        print("  different element counts", file=out)
        return
    count = len(old["flags"])
    flips = []
    for n in range(count):
        kinds = []
        if old["flags"][n] != new["flags"][n]:
            kinds.append(f"flag {old['flags'][n]}->{new['flags'][n]}")
        if old["cracked"][n] != new["cracked"][n]:
            kinds.append(f"cracked {old['cracked'][n]}->{new['cracked'][n]}")
        yielded = (old["barPlastic"][n] != 0, new["barPlastic"][n] != 0)
        if yielded[0] != yielded[1] or (old["barPlastic"][n] < 0) != (new["barPlastic"][n] < 0):
            kinds.append(f"bars {old['barPlastic'][n]:.3g}->{new['barPlastic'][n]:.3g}")
        if (old["compaction"][n] > 0) != (new["compaction"][n] > 0):
            kinds.append("compaction")
        if kinds:
            flips.append((n, kinds, old["damage"][n], new["damage"][n]))
    print(f"  {count} elements, {len(flips)} differ in state", file=out)
    for n, kinds, damage_old, damage_new in flips[:40]:
        print(f"    element {n}: {', '.join(kinds)}; damage {damage_old:.4f} / {damage_new:.4f}", file=out)
    if len(flips) > 40:
        print(f"    ... and {len(flips) - 40} more", file=out)
    damage = [abs(a - b) for a, b in zip(old["damage"], new["damage"])]
    print(f"  damage: largest difference {max(damage, default=0):.3e}, mean {sum(damage) / max(count, 1):.3e}",
          file=out)
    a, b = old["displacement"], new["displacement"]
    if len(a) == len(b) and a:
        lengths = [math.sqrt(a[i] ** 2 + a[i + 1] ** 2 + a[i + 2] ** 2) for i in range(0, len(a), 3)]
        largest = max(lengths)
        differences = [math.sqrt((a[i] - b[i]) ** 2 + (a[i + 1] - b[i + 1]) ** 2 + (a[i + 2] - b[i + 2]) ** 2)
                       for i in range(0, len(a), 3)]
        norm = math.sqrt(sum(x * x for x in lengths))
        print(f"  displacement: largest {largest:.6g} m; difference largest {max(differences):.3e} m "
              f"({max(differences) / largest if largest else 0:.2e} of the largest), "
              f"L2 {math.sqrt(sum(x * x for x in differences)) / norm if norm else 0:.2e} of the field's",
              file=out)
    return flips


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("old")
    parser.add_argument("new")
    parser.add_argument("--dumps", nargs=2, metavar=("OLD", "NEW"), help="--values-dump folders to compare")
    arguments = parser.parse_args()
    worst = compare_lines(read_values(arguments.old), read_values(arguments.new), sys.stdout)
    worst.sort(reverse=True)
    if worst:
        print("largest relative differences:")
        for share, label, key in worst[:10]:
            print(f"  {share:.2e}  {label} {key}")
    if arguments.dumps:
        old_folder, new_folder = (Path(p) for p in arguments.dumps)
        for path in sorted(old_folder.glob("*.json")):
            other = new_folder / path.name
            if other.exists():
                compare_dump(path, other, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
