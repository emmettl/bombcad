#!/usr/bin/env python3
"""Summarize complete moving-piston shock reflection impulse/work comparisons."""
import argparse
import json
import math


def read(path, method):
    with open(path) as source:
        rows = json.load(source)
    expected = {(h, m, v, cfl) for h in [0.05, 0.025, 0.0125, 0.00625]
                for m in [1.2, 2] for v in [-20, 20] for cfl in [0.2, 0.1]}
    index = {(r["cellLength"], r["mach"], r["pistonVelocity"], r["cfl"]): r for r in rows}
    if len(rows) != 32 or set(index) != expected:
        raise ValueError("Expected all 32 moving reflection cases per method")
    for r in rows:
        if r["reconstruction"] != method or len(r["frames"]) != 4 or not math.isfinite(r["relativePressureHistoryL1"]):
            raise ValueError("Mismatched method or incomplete history")
        for f, fraction in zip(r["frames"], [0.8, 1, 1.2, 1.4]):
            if abs(f["arrivalFraction"] - fraction) > 1e-12 or f["time"] >= r["interactionTime"]:
                raise ValueError("Mismatched sample time or boundary interaction")
            if not math.isfinite(f["impulseError"]) or not math.isfinite(f["workError"]):
                raise ValueError("Finite load errors required")
    return index


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("limited", nargs="?", default=".build/moving-reflection.json")
    parser.add_argument("constant", nargs="?", default=".build/moving-reflection-constant.json")
    args = parser.parse_args()
    limited = read(args.limited, "minmodSSPRK2")
    constant = read(args.constant, "constantEuler")
    for index in [constant, limited]:
        for mach in [1.2, 2]:
            for velocity in [-20, 20]:
                for cfl in [0.2, 0.1]:
                    history = [index[h, mach, velocity, cfl]["relativePressureHistoryL1"]
                               for h in [0.05, 0.025, 0.0125, 0.00625]]
                    if any(fine >= coarse for coarse, fine in zip(history, history[1:])):
                        raise ValueError("Pressure-history error must decrease across these grids")
    print("Final impulse errors, normalized by exact excess impulse; CFL 0.1")
    print("Mach  piston(m/s)       dx  constant I%  limited I%  limited W%  constant L1%  limited L1%  CFL I change%")
    for mach in [1.2, 2]:
        for velocity in [-20, 20]:
            for h in [0.05, 0.025, 0.0125, 0.00625]:
                a = constant[h, mach, velocity, 0.1]
                b = limited[h, mach, velocity, 0.1]
                if a["arrivalTime"] != b["arrivalTime"]:
                    raise ValueError("Cases must use identical reference arrivals")
                af, bf = a["frames"][-1], b["frames"][-1]
                if abs(af["exactPistonImpulse"] - bf["exactPistonImpulse"]) > 1e-12:
                    raise ValueError("Cases must use identical reference loads")
                large = limited[h, mach, velocity, 0.2]["frames"][-1]
                delta = large["impulseError"] - bf["impulseError"]
                print(f"{mach:4g} {velocity:12g} {h:8g} {100*af['impulseError']:12.3f} "
                      f"{100*bf['impulseError']:11.3f} {100*bf['workError']:11.3f} "
                      f"{100*a['relativePressureHistoryL1']:13.3f} {100*b['relativePressureHistoryL1']:12.3f} {100*delta:14.4f}")


if __name__ == "__main__":
    main()
