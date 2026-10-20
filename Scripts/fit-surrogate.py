#!/usr/bin/env python3
"""Fit the facade load surrogate's terms (FacadeLoadSurrogate.Coefficients) to district runs.

    python3 Scripts/fit-surrogate.py --out coefficients.json run1.csv:MASS run2.csv:MASS ...

Each CSV is `scenebench surrogate-extract`'s: a run's facade strips with their features and their
recorded peak and impulse. The logarithm of each strip's peak (and impulse) over Kingery-Bulmash's
base (the incident value raised toward the reflected one by the square of its facing) is fitted by
least squares to the terms of FacadeLoadSurrogate.terms (and the share of its first positive phase
spent rising to its peak, itself), each run weighted alike whatever its
number of strips. Strips outside the run's fair part (`inside` 0: near its far-field faces), beyond
the curves (no base) or barely loaded (peak under 100 Pa) are left out. Prints the coefficients as
Swift and writes them as JSON for `scenebench surrogate-judge --coefficients`.

The canyon terms (a street the line runs down) are measured on the fine canyon runs, not fitted to
the districts: `--hold "canyon, peak=peak:0.683"` holds a term's coefficients (those not given at
nothing) while the rest are fitted around them; CSVs before 20 October 2026 carry no canyon
columns, and the terms are nothing there. `--close-in branch.json` adds the close-in branch
(Scripts/fit-close-in.py's) to the JSON. See docs/surrogate-first-look.md
(emmettl/bombcad-work#4).
"""
import json
import sys

import numpy as np

NAMES = ["1", "facing", "facing away", "log(1 + crossed)", "inside buildings / W^(1/3)", "log Z",
         "height / W^(1/3)", "ridge / W^(1/3)", "ground rise / W^(1/3)", "(log Z)^2", "log(cell / W^(1/3))",
         "(log(1 + crossed))^2", "canyon, peak", "canyon, impulse"]


def load(path):
    with open(path) as f:
        head = f.readline().strip().split(",")
    # Two columns of one name would leave only the last in the dict below: before 20 October 2026
    # the rise time shared "rise" with the ground rise, and the ground-rise term was fitted on it.
    repeated = sorted({h for h in head if head.count(h) > 1})
    if repeated:
        raise SystemExit(f"{path}: columns named twice: {', '.join(repeated)} (rename one; the rise time is 'risetime')")
    numeric = [h for h in head if h != "mix"]
    data = np.genfromtxt(path, delimiter=",", skip_header=1, usecols=[head.index(h) for h in numeric])
    return {h: data[:, i] for i, h in enumerate(numeric)}


def canyon(d, mass):
    """FacadeLoadSurrogate.canyonTerms: a street the line runs down, its gain in log peak and impulse."""
    root = mass ** (1 / 3)
    if "canyon" not in d:
        return np.zeros_like(d["cos"]), np.zeros_like(d["cos"])
    street = (d["canyon"] > 0) & (d["canyonheight"] > 0)
    z = np.maximum(d["distance"] / root, 0.2)
    length = d["canyon"] / root
    h = np.maximum(d["canyonheight"] / root, 1e-6)
    u = np.log(np.maximum(z, 2) / np.maximum(z - length, 2))
    peak = np.where(street, u * np.exp(-length / (8 * h)), 0)
    impulse = np.where(street & (h > 0.6), u * np.exp(-length / (3 * h)) * (1 - np.exp(-(h - 0.6))), 0)
    return peak, impulse


def terms(d, mass):
    root = mass ** (1 / 3)
    c = d["cos"]
    z = np.log(np.maximum(d["distance"] / root, 0.2))
    cp, ci = canyon(d, mass)
    return np.column_stack([
        np.ones_like(c), np.maximum(c, 0), np.maximum(-c, 0), np.log1p(d["crossed"]), d["blocked"] / root,
        z, d["height"] / root, d["ridge"] / root, d["rise"] / root, z * z, np.log(d["cell"] / root),
        np.log1p(d["crossed"]) ** 2, cp, ci,
    ])


def base(d):
    facing = np.maximum(d["cos"], 0) ** 2
    return d["pso"] + facing * (d["pr"] - d["pso"]), d["iso"] + facing * (d["ir"] - d["iso"])


def prepared(path, mass):
    d = load(path)
    keep = (d["inside"] > 0) & (d["pso"] > 0) & (d["peak"] > 100) & (d["impulse"] > 0)
    d = {k: v[keep] for k, v in d.items()}
    p, i = base(d)
    share = d["risetime"] / (2 * d["impulse"] / d["peak"])
    return (terms(d, mass), np.log(d["peak"] / p), np.log(d["impulse"] / i), d["distance"] / mass ** (1 / 3),
            np.clip(share, 0, 1))


def main(argv):
    out = None
    if "--out" in argv:
        k = argv.index("--out")
        out = argv[k + 1]
        argv = argv[:k] + argv[k + 2:]
    # `--drop facing,...`: terms held at nothing (a roof's facing toward a charge on the ground is a
    # sliver of a cosine, and fitting it runs away).
    dropped = set()
    if "--drop" in argv:
        k = argv.index("--drop")
        dropped = set(argv[k + 1].split(","))
        argv = argv[:k] + argv[k + 2:]
    # `--hold "name=peak:v,impulse:v"` (repeatable): a term's coefficients held, those not given at
    # nothing, the rest fitted around them.
    held = {}
    while "--hold" in argv:
        k = argv.index("--hold")
        name, values = argv[k + 1].split("=", 1)
        held[name] = {t: 0.0 for t in ("peak", "impulse", "rise")}
        for part in values.split(","):
            t, v = part.split(":")
            held[name][t] = float(v)
        argv = argv[:k] + argv[k + 2:]
    close_in = None
    if "--close-in" in argv:
        k = argv.index("--close-in")
        with open(argv[k + 1]) as f:
            close_in = json.load(f)
        argv = argv[:k] + argv[k + 2:]
    unknown = (dropped | set(held)) - set(NAMES)
    if unknown:
        print(f"unknown terms to drop or hold: {sorted(unknown)}")
        return 1
    kept = [n for n, name in enumerate(NAMES) if name not in dropped and name not in held]
    hold = [n for n, name in enumerate(NAMES) if name in held]
    runs = []
    for arg in argv:
        path, mass = arg.rsplit(":", 1)
        runs.append((path, *prepared(path, float(mass))))
    if not runs:
        print(__doc__)
        return 1
    x = np.vstack([r[1] for r in runs])
    w = np.concatenate([np.full(len(r[2]), 1 / len(r[2])) for r in runs])
    sw = np.sqrt(w)[:, None]
    fits = {}
    for name, column in (("peak", 2), ("impulse", 3), ("rise", 5)):
        y = np.concatenate([r[column] for r in runs])
        b = np.zeros(len(NAMES))
        for n in hold:
            b[n] = held[NAMES[n]][name]
        bk, *_ = np.linalg.lstsq(x[:, kept] * sw, (y - x @ b) * sw[:, 0], rcond=None)
        b[kept] = bk
        fits[name] = b
        for path, xr, yp, yi, _, share in runs:
            residual = {"peak": yp, "impulse": yi, "rise": share}[name] - xr @ b
            print(f"{name} {path}: {len(residual)} strips, log sd {residual.std():.3f}, mean {residual.mean():+.3f}")
    scatter = []
    for name, column in (("peak", 2), ("impulse", 3)):
        residual = np.concatenate([r[column] - r[1] @ fits[name] for r in runs])
        scatter.append(float(np.sqrt(np.average(residual ** 2, weights=w))))
    z = np.concatenate([r[4] for r in runs])
    low, high = (float(v) for v in np.percentile(z, [2, 98]))
    for name in ("peak", "impulse", "rise"):
        print(name + ": " + ", ".join(f"{n} {v:+.3f}" for n, v in zip(NAMES, fits[name])))
    print(f"scaled distances {low:.1f}-{high:.1f} m/kg^(1/3) (2nd to 98th percentile), scatter {scatter}")
    fitted = " + ".join(r[0].rsplit("/", 1)[-1] for r in runs)
    print("Swift:")
    print(f"        peak: [{', '.join(f'{v:.3f}' for v in fits['peak'])}],")
    print(f"        impulse: [{', '.join(f'{v:.3f}' for v in fits['impulse'])}],")
    print(f"        rise: [{', '.join(f'{v:.3f}' for v in fits['rise'])}],")
    print(f"        scaledRange: {low:.1f}...{high:.1f}, scatter: SIMD2({scatter[0]:.3f}, {scatter[1]:.3f}),")
    print(f'        fittedTo: "{fitted}")')
    if close_in:
        print(f"        closeIn: {close_in}")
    if out:
        with open(out, "w") as f:
            body = {"peak": [float(v) for v in fits["peak"]], "impulse": [float(v) for v in fits["impulse"]],
                    "rise": [float(v) for v in fits["rise"]],
                    "scaledRange": [low, high], "scatter": scatter, "fittedTo": fitted}
            if close_in:
                body["closeIn"] = close_in
            json.dump(body, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
