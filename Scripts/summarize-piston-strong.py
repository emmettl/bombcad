#!/usr/bin/env python3
"""Compare analytical strong-wave errors and merge costs at nominal CFL 0.2."""
import json
import sys


def read(path):
    with open(path) as source:
        runs = json.load(source)
    expected = {(h, c, m, v) for h in [0.1, 0.05, 0.025, 0.0125]
                for c in [0.4, 0.2] for m in [0.125, 0.25, 0.5] for v in [-100, 100]}
    index = {(r["cellLength"], r["cfl"], r["mergeFraction"], r["pistonVelocity"]): r for r in runs}
    if len(runs) != 48 or set(index) != expected:
        raise ValueError("Expected a complete 48-case strong-wave merge report")
    if any([f["time"] for f in r["frames"]] != [0.0005, 0.0008] for r in runs):
        raise ValueError("Expected matching pre-reflection snapshot times")
    return index


def main():
    baseline = read(sys.argv[1] if len(sys.argv) > 1 else ".build/piston-wave-strong-merges.json")
    limited = read(sys.argv[2] if len(sys.argv) > 2 else ".build/piston-wave-limited-strong-merges.json")
    print("At 0.8 ms, nominal CFL 0.2; pressure L1 normalised by incident pressure")
    print("speed      dx  merge  constant%  limited%  |work error|%  steps  retries")
    for speed in [-100, 100]:
        for h in [0.1, 0.05, 0.025, 0.0125]:
            for merge in [0.125, 0.25, 0.5]:
                key = h, 0.2, merge, speed
                a, b = baseline[key]["frames"][-1], limited[key]["frames"][-1]
                print(f"{speed:5} {h:7g} {merge:6g} {100*a['relativePressureL1']:10.4f} "
                      f"{100*b['relativePressureL1']:9.4f} {100*abs(b['relativeWallWorkError']):14.4f} "
                      f"{b['steps']:6} {b['rejectedSteps']:8}")


if __name__ == "__main__":
    main()
