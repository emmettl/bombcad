#!/usr/bin/env python3
"""The calibration's design (docs/calibration.md): today's values, then a Latin hypercube over
the parameters, uniform in their logarithms, as a JSON list for `BombCAD ensemble --design`.

    python3 Scripts/calibration/design.py [--points 12] [--seed 1] [--parameters ft,gf] > design.json

`--parameters` spreads only those (the ones a case reads); the others are left to the case's own
middle values, which are today's.
"""
import json
import math
import random
import sys

# Each parameter: its key in a sample's values, its range and today's value.
PARAMETERS = [
    # Seconds per kg^(1/3) over which products that have met air burn (`afterburnTime`).
    ("afterburnTime", 0.003, 0.03, 0.01),
    # A factor on every concrete's tensile strength (`ValidationEnsemble.perturbed`).
    ("ft", 0.6, 1.6, 1.0),
    # A factor on every concrete's fracture and crushing energies, on their correlation with its
    # strength (`ValidationEnsemble.perturbed`): the ensemble's 30% log-normal, about twice over.
    ("gf", 0.5, 2.0, 1.0),
    # A factor on the glass flaw constant k, or the share of a pane at its largest stress.
    ("glassK", 0.01, 3.0, 1.0),
]


def latin_hypercube(points, dimensions, seed):
    """`points` points in the unit cube, one in each of `points` slices of every axis, each at a
    random place in its slice."""
    generator = random.Random(seed)
    columns = []
    for _ in range(dimensions):
        order = list(range(points))
        generator.shuffle(order)
        columns.append([(slot + generator.random()) / points for slot in order])
    return [[columns[d][n] for d in range(dimensions)] for n in range(points)]


def design(points, seed, keys=None):
    chosen = [p for p in PARAMETERS if keys is None or p[0] in keys]
    today = {key: value for key, _, _, value in chosen}
    rows = [today]
    for unit in latin_hypercube(points, len(chosen), seed):
        rows.append({
            key: math.exp(math.log(low) + u * (math.log(high) - math.log(low)))
            for (key, low, high, _), u in zip(chosen, unit)
        })
    return rows


def main(arguments):
    def option(name, default):
        return arguments[arguments.index(name) + 1] if name in arguments else default
    keys = option("--parameters", None)
    print(json.dumps(design(int(option("--points", "12")), int(option("--seed", "1")),
                            keys.split(",") if keys else None), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
