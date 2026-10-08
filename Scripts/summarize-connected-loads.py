#!/usr/bin/env python3
"""Summarise the complete matched-energy held-box grid/CFL comparison."""
import json
import math
import sys


def norm(vector):
    return math.sqrt(sum(component * component for component in vector))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ".build/connected-loads-convergence.json"
    with open(path) as source:
        rows = json.load(source)
    expected = {(h, angle, cfl) for h in [0.2, 0.1, 0.05] for angle in [0, 0.23] for cfl in [0.2, 0.1]}
    index = {(r["cellSize"], r["rotation"], r["cfl"]): r for r in rows}
    if len(rows) != 12 or set(index) != expected:
        raise ValueError("Expected a complete twelve-case load comparison")
    if any(r["duration"] != 0.0005 or abs(r["pulseEnergy"] / 6400 - 1) > 1e-10 for r in rows):
        raise ValueError("Cases must use matched time and 6400 J pulse energy")
    initializations = {r.get("initialization", "cellCentre") for r in rows}
    if len(initializations) != 1:
        raise ValueError("Cases must use the same initialization method")
    transports = {r.get("transport", "constantEuler") for r in rows}
    if len(transports) != 1:
        raise ValueError("Cases must use the same transport method")
    wall_methods = {r.get("wallIntegration", "centroid") for r in rows}
    if len(wall_methods) != 1:
        raise ValueError("Cases must use the same wall integration method")
    print(f"Wall integration: {next(iter(wall_methods))}")
    print(f"Transport: {next(iter(transports))}")
    print(f"Initialization: {next(iter(initializations))}")
    print("CFL 0.1 loads; grid changes compare with the preceding coarser grid")
    print("rotation   dx    Ix(N s)  grid Ix%  angular vector%  CFL Ix%  amplitude(Pa)")
    for angle in [0, 0.23]:
        previous = None
        for h in [0.2, 0.1, 0.05]:
            current = index[h, angle, 0.1]
            large_step = index[h, angle, 0.2]
            impulse = current["bodyImpulse"][0]
            cfl_change = 100 * (large_step["bodyImpulse"][0] / impulse - 1)
            grid_change = angular_change = "--"
            if previous:
                grid_change = f"{100 * (impulse / previous['bodyImpulse'][0] - 1):.3f}"
                delta = [a - b for a, b in zip(current["bodyAngularImpulse"], previous["bodyAngularImpulse"])]
                angular_change = f"{100 * norm(delta) / norm(previous['bodyAngularImpulse']):.3f}"
            print(f"{angle:8g} {h:5g} {impulse:10.6f} {grid_change:>9} {angular_change:>16} "
                  f"{cfl_change:8.3f} {current['pulseAmplitude']:14.3f}")
            previous = current


if __name__ == "__main__":
    main()
