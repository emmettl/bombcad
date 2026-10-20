#!/usr/bin/env python3
"""Fit the façade surrogate's close-in branch (FacadeLoadSurrogate.Coefficients.CloseIn) on fine runs.

    python3 Scripts/fit-close-in.py --fit fit.json [--out branch.json] run1.csv:MASS run2.csv:MASS ...

Each CSV is `scenebench surrogate-extract`'s, of a run on cells fine against the charge (the
protective layouts on 0.5 m cells at 1 t, emmettl/bombcad-work#4). Its open façades (nothing under the
line from the charge, facing it by a cosine over 0.3, Z within the branch's hold) give log(load /
base), base Kingery-Bulmash's incident value raised toward the reflected by the square of the
facing, as a quadratic in log Z; each run's cells are carried to the reference (0.05 W^(1/3)) by
`fit.json`'s own cell term, which the surrogate then applies to the user's cells. Prints the branch,
its scatter, and the scatter leaving one run out; writes the JSON for fit-surrogate.py --close-in.
"""
import importlib.util
import json
import os
import sys

import numpy as np

spec = importlib.util.spec_from_file_location("fit", os.path.join(os.path.dirname(__file__), "fit-surrogate.py"))
fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit)

HELD = (1.5, 8.0)
REFERENCE = 0.05


def main(argv):
    out = None
    if "--out" in argv:
        k = argv.index("--out")
        out = argv[k + 1]
        argv = argv[:k] + argv[k + 2:]
    if "--fit" not in argv:
        print(__doc__)
        return 1
    k = argv.index("--fit")
    with open(argv[k + 1]) as f:
        main_fit = json.load(f)
    argv = argv[:k] + argv[k + 2:]
    runs = []
    for arg in argv:
        path, mass = arg.rsplit(":", 1)
        mass = float(mass)
        d = fit.load(path)
        root = mass ** (1 / 3)
        z = d["distance"] / root
        keep = ((d["inside"] > 0) & (d["pso"] > 0) & (d["peak"] > 100) & (d["impulse"] > 0) & (d["edge"] < -900)
                & (d["cos"] > 0.3) & (z >= HELD[0]) & (z <= HELD[1]))
        d = {key: v[keep] for key, v in d.items()}
        p, i = fit.base(d)
        lz = np.log(np.clip(d["distance"] / root, *HELD))
        cell = np.log(d["cell"] / root) - np.log(REFERENCE)
        runs.append((path, lz, cell, np.log(d["peak"] / p), np.log(d["impulse"] / i)))
    branch = {}
    for name, column, term in (("peak", 3, main_fit["peak"][10]), ("impulse", 4, main_fit["impulse"][10])):
        A = np.vstack([np.column_stack([np.ones_like(r[1]), r[1], r[1] ** 2]) for r in runs])
        y = np.concatenate([r[column] - term * r[2] for r in runs])
        b, *_ = np.linalg.lstsq(A, y, rcond=None)
        start = 0
        left = []
        for n, r in enumerate(runs):
            m = np.zeros(len(y), bool)
            m[start:start + len(r[1])] = True
            start += len(r[1])
            if len(runs) > 1:
                bb, *_ = np.linalg.lstsq(A[~m], y[~m], rcond=None)
                left.append(y[m] - A[m] @ bb)
        out_sd = f", leaving one run out {np.concatenate(left).std():.3f}" if left else ""
        print(f"{name}: {', '.join(f'{v:+.3f}' for v in b)} in (log Z)^0..2, {len(y)} façades, sd {np.std(y - A @ b):.3f}{out_sd}")
        branch[name] = [float(v) for v in b]
    branch.update(referenceCell=REFERENCE, heldWithin=list(HELD), blendTo=HELD[1],
                  fittedTo=" + ".join(os.path.basename(r[0]) for r in runs))
    if out:
        with open(out, "w") as f:
            json.dump(branch, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
