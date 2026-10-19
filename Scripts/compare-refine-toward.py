#!/usr/bin/env python3
"""Refinement toward chosen buildings against refining everywhere and the coarse cells alone.

Reads three `scenebench district-compare --out` reports (comparison.json) of one district: the
coarse cells, refined everywhere, and refined toward buildings (`--refine-toward`), and for the
buildings nearest the given points sets side by side each run's answer for them: their concrete
and stone damage levels, how many of their sides' glass breaks at the median strength, and their
sides' highest net pressure, with each run's wall time and refined block-steps
(docs/refinement-steering.md).

    python3 Scripts/compare-refine-toward.py coarse.json everywhere.json toward.json --at x,y[;x,y]
"""

import json
import math
import sys


def load(path):
    with open(path) as handle:
        return json.load(handle)


def nearest(report, point):
    best, distance = None, math.inf
    for building in report["buildings"]:
        centre = building.get("centreM")
        if not centre:
            continue
        d = math.hypot(centre[0] - point[0], centre[1] - point[1])
        if d < distance:
            best, distance = building, d
    return best


def answer(building):
    if building is None:
        return "not judged"
    sides = building["sides"]
    broken = sum(1 for side in sides if side["brokenMedian"])
    peak = max((side["peakNetPa"] for side in sides), default=0)
    return f"concrete {building['concrete']}, stone {building['stone']}, glass {broken}/{len(sides)} sides, peak {peak / 1e3:.1f} kPa"


def main(argv):
    if len(argv) < 5 or argv[4] != "--at":
        print(__doc__.strip())
        return 2
    names = ["coarse", "everywhere", "toward"]
    reports = [load(path) for path in argv[1:4]]
    points = [[float(v) for v in item.split(",")[:2]] for item in argv[5].split(";")]
    for name, report in zip(names, reports):
        steps = report.get("refinedBlockSteps")
        work = f", refined block-steps {sum(steps):,}" if steps else ""
        print(f"{name}: wall {report['wallS']:.0f} s{work}")
    everywhere = reports[1].get("refinedBlockSteps")
    toward = reports[2].get("refinedBlockSteps")
    if everywhere and toward and sum(everywhere) > 0:
        print(f"toward holds {100 * sum(toward) / sum(everywhere):.1f}% of refining everywhere's block-steps")
    for point in points:
        found = [nearest(report, point) for report in reports]
        distance = found[2]["distanceM"] if found[2] else float("nan")
        print(f"\nThe building nearest ({point[0]:.0f}, {point[1]:.0f}) m, {distance:.0f} m from the charge:")
        for name, building in zip(names, found):
            print(f"  {name:>10}: {answer(building)}")
        same = found[1] and found[2] and all(
            found[1][key] == found[2][key] for key in ("concrete", "stone")
        ) and [s["brokenMedian"] for s in found[1]["sides"]] == [s["brokenMedian"] for s in found[2]["sides"]]
        print("  toward gives refining everywhere's answer" if same else "  toward differs from refining everywhere")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
