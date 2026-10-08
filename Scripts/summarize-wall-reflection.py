#!/usr/bin/env python3
"""Compare complete exact shock-reflection history benchmarks across grids and CFL."""
import argparse
import json
import math


def read(path, method, grids=(0.1, 0.05, 0.025, 0.0125), cfls=(0.2, 0.1)):
    with open(path) as source:
        rows = json.load(source)
    expected = {(h, mach, cfl) for h in grids for mach in [1.2, 2] for cfl in cfls}
    index = {(r["cellLength"], r["mach"], r["cfl"]): r for r in rows}
    if len(rows) != len(expected) or set(index) != expected:
        raise ValueError(f"Expected all {len(expected)} reflection cases per method")
    for r in rows:
        if (r["transport"] != method or r["duration"] >= r["interactionTime"]
                or abs(r["duration"] / r["arrivalTime"] - 1.4) > 1e-12
                or [f["arrivalFraction"] for f in r["frames"]] != [0.8, 1, 1.2, 1.4]
                or not math.isfinite(r["relativePressureHistoryL1"])):
            raise ValueError("Mismatched history method or unsupported reference time")
    return index


def same_reference(a, b):
    if a["arrivalTime"] != b["arrivalTime"] or a["reflectedPressure"] != b["reflectedPressure"]:
        raise ValueError("Methods must use identical shock references")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("constant", nargs="?", default=".build/wall-reflection.json")
    parser.add_argument("limited", nargs="?", default=".build/wall-reflection-limited.json")
    parser.add_argument("--refined", nargs="?", const=".build/wall-reflection-limited-refined.json")
    args = parser.parse_args()
    constant = read(args.constant, "constantEuler")
    limited = read(args.limited, "limitedSSPRK2")
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
            same_reference(a, b)
            cfl_change = limited[h, mach, 0.2]["relativePressureHistoryL1"] / b["relativePressureHistoryL1"] - 1
            print(f"{mach:4g} {h:7g} {100*a['relativePressureHistoryL1']:14.3f} "
                  f"{100*b['relativePressureHistoryL1']:12.3f} "
                  f"{100*a['frames'][-1]['impulseError']:18.3f} "
                  f"{100*b['frames'][-1]['impulseError']:17.3f} {100*cfl_change:16.3f}")
    if args.refined:
        fine = read(args.refined, "limitedSSPRK2", grids=(0.00625, 0.003125), cfls=(0.2,))
        print("\nFurther reconstruction refinement at CFL 0.2; rise times use step-average pressure")
        print("Mach       dx    history L1%   impulse%   midpoint arrival error%   10–90 rise width(us)")
        for mach in [1.2, 2]:
            previous = None
            for h in [0.0125, 0.00625, 0.003125]:
                r = limited[h, mach, 0.2] if h == 0.0125 else fine[h, mach, 0.2]
                same_reference(limited[0.0125, mach, 0.2], r)
                times = [r.get(key) for key in ["rise10Time", "rise50Time", "rise90Time"]]
                if any(t is None or not math.isfinite(t) for t in times) or not (0 <= times[0] < times[1] < times[2] < r["duration"]):
                    raise ValueError("Ordered rise times required; rerun the limited benchmark with the current driver")
                width = times[2] - times[0]
                if previous and (r["relativePressureHistoryL1"] >= previous[0] or width >= previous[1]):
                    raise ValueError("Further refinement must reduce history error and rise width")
                bias = times[1] / r["arrivalTime"] - 1
                print(f"{mach:4g} {h:8g} {100*r['relativePressureHistoryL1']:14.3f} "
                      f"{100*r['frames'][-1]['impulseError']:10.3f} {100*bias:25.3f} {width*1e6:22.3f}")
                previous = (r["relativePressureHistoryL1"], width)


if __name__ == "__main__":
    main()
