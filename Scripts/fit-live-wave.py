#!/usr/bin/env python3
"""Fits the live blast wave's correction to Kingery–Bulmash (`LiveWave.Coefficients`;
docs/live-wave.md) on cells sampled from BombCAD's 4 m district runs by
`blastmodel live-wave-judge --coefficients none --samples file.tsv`.

    python3 -I Scripts/fit-live-wave.py --peaks peaks.tsv [--arrivals arrivals.tsv] [--out fit.json]

The peak's log over Kingery–Bulmash's at the path's length is fitted as
c0 + c1 x + c2 x² + c3 s + c4 s x, with x = ln Z of the path and s = ln(L/R), the path's excess
over the straight line; the arrival's as a0 + a1 x + a2 s. Each run weighs alike; cells under
200 Pa in the run, and those within 50 m of the charge, are left out. Ranges are the 2nd to 98th percentiles of x and s.
"""

import argparse
import csv
import json
import math
import sys

import numpy as np


def read(path):
    with open(path) as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    return rows


def features(rows, target):
    x, s, y, w, runs = [], [], [], [], []
    for r in rows:
        mass = float(r["massKg"])
        path = float(r["pathM"])
        straight = float(r["straightM"])
        # Close in the cells' arrivals are milliseconds, read off the mapped start's own front.
        if not (math.isfinite(path) and path > 0 and straight >= 50):
            continue
        if target == "peak":
            run, base = float(r["runPeakPa"]), float(r["livePeakPa"])
            if run < 200 or base <= 0:
                continue
        else:
            run, base = float(r["runArrivalS"]), float(r["liveArrivalS"])
            if not (math.isfinite(run) and run > 0 and math.isfinite(base) and base > 0):
                continue
        x.append(math.log(max(path, 2.0) / mass ** (1 / 3)))
        s.append(math.log(max(path, 1e-3) / max(straight, 1e-3)))
        y.append(math.log(run / base))
        runs.append(r["run"])
    counts = {}
    for run in runs:
        counts[run] = counts.get(run, 0) + 1
    w = [1.0 / counts[run] for run in runs]
    return np.array(x), np.array(s), np.array(y), np.array(w)


def fit(design, y, w):
    sw = np.sqrt(w)
    coef, *_ = np.linalg.lstsq(design * sw[:, None], y * sw, rcond=None)
    residual = y - design @ coef
    sd = math.sqrt(float(np.sum(w * residual**2) / np.sum(w)))
    return coef, sd


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--peaks", required=True)
    parser.add_argument("--arrivals")
    parser.add_argument("--out")
    args = parser.parse_args()

    x, s, y, w = features(read(args.peaks), "peak")
    lo, hi = np.percentile(x, [2, 98])
    slo, shi = 0.0, float(np.percentile(s, 98))
    xc, sc = np.clip(x, lo, hi), np.clip(s, slo, shi)
    design = np.column_stack([np.ones_like(xc), xc, xc**2, sc, sc * xc])
    peak, peak_sd = fit(design, y, w)
    print(f"peak: {len(y)} cells, ln-scatter before {math.sqrt(float(np.sum(w * y**2) / np.sum(w))):.3f}, after {peak_sd:.3f}")
    print("  terms", ", ".join(f"{c:.4f}" for c in peak))

    arrival = np.zeros(3)
    if args.arrivals:
        ax, as_, ay, aw = features(read(args.arrivals), "arrival")
        axc, asc = np.clip(ax, lo, hi), np.clip(as_, slo, shi)
        design = np.column_stack([np.ones_like(axc), axc, asc])
        arrival, arrival_sd = fit(design, ay, aw)
        print(f"arrival: {len(ay)} cells, ln-scatter before {math.sqrt(float(np.sum(aw * ay**2) / np.sum(aw))):.4f}, after {arrival_sd:.4f}")
        print("  terms", ", ".join(f"{c:.5f}" for c in arrival))

    result = {
        "peak": [float(c) for c in peak],
        "arrival": [float(c) for c in arrival],
        "logZRange": [float(lo), float(hi)],
        "excessRange": [slo, shi],
    }
    text = json.dumps(result, indent=2)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    sys.exit(main())
