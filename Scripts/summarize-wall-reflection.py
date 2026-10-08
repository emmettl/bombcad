#!/usr/bin/env python3
"""Compare complete exact shock-reflection history benchmarks across grids and CFL."""
import json
import math
import sys


def read(path, method):
    with open(path) as source:
        rows = json.load(source)
    expected = {(h, mach, cfl) for h in [0.1, 0.05, 0.025, 0.0125]
                for mach in [1.2, 2] for cfl in [0.2, 0.1]}
    index = {(r["cellLength"], r["mach"], r["cfl"]): r for r in rows}
    if len(rows) != 16 or set(index) != expected:
        raise ValueError("Expected all sixteen reflection cases per method")
    for r in rows:
        if (r["transport"] != method or r["duration"] >= r["interactionTime"]
                or abs(r["duration"] / r["arrivalTime"] - 1.4) > 1e-12
                or [f["arrivalFraction"] for f in r["frames"]] != [0.8, 1, 1.2, 1.4]
                or not math.isfinite(r["relativePressureHistoryL1"])):
            raise ValueError("Mismatched history method or unsupported reference time")
    return index


def main():
    constant = read(sys.argv[1] if len(sys.argv) > 1 else ".build/wall-reflection.json", "constantEuler")
    limited = read(sys.argv[2] if len(sys.argv) > 2 else ".build/wall-reflection-limited.json", "limitedSSPRK2")
    for index in [constant, limited]:
        for mach in [1.2, 2]:
            for cfl in [0.2, 0.1]:
                history = [index[h, mach, cfl]["relativePressureHistoryL1"]
                           for h in [0.1, 0.05, 0.025, 0.0125]]
                if any(fine >= coarse for coarse, fine in zip(history, history[1:])):
                    raise ValueError("Pressure-history error must decrease on these benchmark grids")
    print("CFL 0.1 errors against the exact step wall-pressure/impulse history")
    print("Mach    dx   constant L1%  limited L1%  constant impulse%  limited impulse%  limited CFL L1%")
    for mach in [1.2, 2]:
        for h in [0.1, 0.05, 0.025, 0.0125]:
            a = constant[h, mach, 0.1]
            b = limited[h, mach, 0.1]
            if a["arrivalTime"] != b["arrivalTime"] or a["reflectedPressure"] != b["reflectedPressure"]:
                raise ValueError("Methods must use identical shock references")
            cfl_change = limited[h, mach, 0.2]["relativePressureHistoryL1"] / b["relativePressureHistoryL1"] - 1
            print(f"{mach:4g} {h:7g} {100*a['relativePressureHistoryL1']:14.3f} "
                  f"{100*b['relativePressureHistoryL1']:12.3f} "
                  f"{100*a['frames'][-1]['impulseError']:18.3f} "
                  f"{100*b['frames'][-1]['impulseError']:17.3f} {100*cfl_change:16.3f}")


if __name__ == "__main__":
    main()
