#!/usr/bin/env python3
"""Compares the fireball's thermal radiation with Dial Pack's, measured in DREO Report 642.

Reads Samples/DialPack1970/dial-pack-1970.json and the frames `blastbench dialpack --csv` wrote,
and prints, for each run: the radiant intensity toward the 1,700 m instrument against the
bolometer's, both free of the atmosphere; the fluence at 600 and 1,700 m against the measured
fluence by the same time; and the energy radiated by then, by the report's own reckoning from the
1,700 m instrument (4 pi r^2 times the fluence), measured round the fireball, and lost by the gas.

    python3 Scripts/compare-dial-pack.py run.csv [other.csv ...]

See docs/thermal-radiation.md#against-dial-pack.
"""

import csv
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAL = 4.184  # J
MODELS = ("volume", "shape", "sphere")


def interpolate(xs, ys, x):
    if x <= xs[0]:
        return ys[0]
    for (x0, y0), (x1, y1) in zip(zip(xs, ys), zip(xs[1:], ys[1:])):
        if x <= x1:
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    return ys[-1]


def measured(data):
    """The bolometer's intensity, W/sr, at its times, s, and 4 pi times its integral, J."""
    rows = data["bolometer"]["rows"]
    times = [r[0] / 1000 for r in rows]
    intensity = [r[3] * 1e7 * CAL for r in rows]
    energy = [0.0]
    for n in range(1, len(rows)):
        energy.append(energy[-1] + 4 * math.pi * 0.5 * (intensity[n - 1] + intensity[n]) * (times[n] - times[n - 1]))
    return times, intensity, energy


def compare(path, data):
    frames = list(csv.DictReader(open(path)))
    t = [float(f["time_s"]) for f in frames]
    end = t[-1]
    times, intensity, energy = measured(data)
    print(f"\n{os.path.basename(path)}, to {end * 1000:.0f} ms")
    print("Radiant intensity toward 1,700 m, cal/sr/s x 1e7 (free of the atmosphere):")
    print(f"  {'ms':>6} {'measured':>9} " + " ".join(f"{m:>8}" for m in MODELS))
    for tm, j in zip(times, intensity):
        if tm > end + 1e-9:
            break
        row = []
        for m in MODELS:
            h = interpolate(t, [float(f[f"{m}_1700_W_m2"]) for f in frames], tm)
            row.append(h * 1700**2 / CAL / 1e7)
        print(f"  {tm * 1000:6.2f} {j / CAL / 1e7:9.0f} " + " ".join(f"{v:8.0f}" for v in row))
    so_far = interpolate(times, energy, end)
    print(f"Fluence by {end * 1000:.0f} ms, kJ/m2 (measured: the bolometer's 4 pi integral over 4 pi r^2):")
    for r in (600, 1700):
        line = f"  {r:5d} m: measured {so_far / (4 * math.pi * r * r) / 1000:.3f}"
        for m in MODELS:
            h = [float(f[f"{m}_{r}_W_m2"]) for f in frames]
            u = sum(0.5 * (a + b) * (t1 - t0) for a, b, t0, t1 in zip(h, h[1:], t, t[1:]))
            line += f"; {m} {u / 1000:.3f}"
        print(line)
    basis = data["charge"]["blastYieldCal"] * CAL
    print(f"Radiated by {end * 1000:.0f} ms, as a share of the report's blast yield ({basis:.3g} J):")
    print(f"  measured, from the bolometer: {100 * so_far / basis:.3f}%")
    for m in MODELS:
        h = [float(f[f"{m}_1700_W_m2"]) for f in frames]
        u = sum(0.5 * (a + b) * (t1 - t0) for a, b, t0, t1 in zip(h, h[1:], t, t[1:]))
        print(f"  {m}, by the report's reckoning from 1,700 m: {100 * 4 * math.pi * 1700**2 * u / basis:.3f}%")
    power = [float(f["radiated_W"]) for f in frames]
    round_it = sum(0.5 * (a + b) * (t1 - t0) for a, b, t0, t1 in zip(power, power[1:], t, t[1:]))
    print(f"  the volume, measured round it: {100 * round_it / basis:.3f}%")
    lost = float(frames[-1]["gas_lost_J"])
    if lost > 0:
        print(f"  lost by the gas: {100 * lost / basis:.3f}%")
    total = data["thermalYield"]["rows"][-1]["energyCal"] * CAL
    print(f"  (the whole measured pulse, 15 s: {100 * total / basis:.1f}%)")


def main():
    data = json.load(open(os.path.join(ROOT, "Samples/DialPack1970/dial-pack-1970.json")))
    for path in sys.argv[1:]:
        compare(path, data)


if __name__ == "__main__":
    main()
