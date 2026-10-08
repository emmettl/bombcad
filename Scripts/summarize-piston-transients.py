#!/usr/bin/env python3
"""Compare complete piecewise-constant piston profiles by interval overlap."""
import json
import sys


def boundaries(frame):
    total = sum(frame["cellVolumes"])
    result = [0.0]
    for volume in frame["cellVolumes"]:
        result.append(result[-1] + volume / total)
    result[-1] = 1.0
    return result


def pressure_difference(frame, reference):
    a, b = boundaries(frame), boundaries(reference)
    edges = sorted(set(a + b))
    i = j = 0
    error = 0.0
    for low, high in zip(edges, edges[1:]):
        middle = (low + high) / 2
        while i < len(a) - 2 and middle >= a[i + 1]:
            i += 1
        while j < len(b) - 2 and middle >= b[j + 1]:
            j += 1
        error += (high - low) * abs(frame["cellPressures"][i] - reference["cellPressures"][j])
    return error / reference["meanPressure"]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ".build/piston-transients.json"
    with open(path) as source:
        runs = json.load(source)
    index = {(r["pistonVelocity"], r["cellLength"], r["cfl"]): r for r in runs}
    expected = {(v, h, c) for v in [-20, 20] for h in [0.1, 0.05, 0.025] for c in [0.4, 0.2]}
    if set(index) != expected or len(runs) != 12:
        raise ValueError("Expected a complete twelve-trajectory transient report")
    print("Relative L1 pressure difference (%); reference dx=0.025, CFL=0.2")
    print("speed   time(s)    dx=0.1    dx=0.05    finest CFL change")
    for speed in [-20, 20]:
        reference = index[speed, 0.025, 0.2]
        for n, frame in enumerate(reference["frames"]):
            others = [index[speed, h, c]["frames"][n] for h, c in [(0.1, 0.2), (0.05, 0.2), (0.025, 0.4)]]
            if any(other["time"] != frame["time"] for other in others):
                raise ValueError("Profiles must refer to identical physical times")
            values = [100 * pressure_difference(other, frame) for other in others]
            print(f"{speed:5} {frame['time']:9.4g} {values[0]:10.5f} {values[1]:10.5f} {values[2]:18.5f}")


if __name__ == "__main__":
    main()
