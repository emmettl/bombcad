#!/usr/bin/env python3
"""A stand-in for training, in pure Python: for testing remote-train.py on a host without PyTorch.

    python3 standin_train.py --data DATASET --out OUT [--epochs 20] [--cells 4000] [--seed 0]

Reads the field dataset's .npy files itself (little-endian float32, as scenebench field-export
writes them), samples cells under each run's mask, and fits ln(peak / Kingery–Bulmash) as a line
in ln Z by gradient descent, printing the loss each epoch. Writes OUT/model.json and
OUT/metrics.json. It proves the plumbing (the data arrive, the script runs, its output comes back),
not a model.
"""
import argparse
import json
import math
import os
import random
import struct
import sys
import time


def read_npy(path):
    """(shape, values) of a little-endian float32 .npy file, version 1 or 2."""
    with open(path, "rb") as handle:
        if handle.read(6) != b"\x93NUMPY":
            raise ValueError("%s is not a .npy file" % path)
        major = handle.read(2)[0]
        length = struct.unpack("<H" if major == 1 else "<I", handle.read(2 if major == 1 else 4))[0]
        header = handle.read(length).decode("latin1")
        if "'<f4'" not in header or "'fortran_order': False" not in header:
            raise ValueError("%s: only C-ordered little-endian float32 is read here" % path)
        shape = tuple(int(n) for n in header.split("'shape': (")[1].split(")")[0].split(",") if n.strip())
        count = 1
        for n in shape:
            count *= n
        values = struct.unpack("<%df" % count, handle.read(4 * count))
    return shape, values


def samples(dataset, per_run, rng):
    """[(ln Z, ln(peak / KB peak))] at up to `per_run` masked cells of each run."""
    out = []
    runs = sorted(os.listdir(os.path.join(dataset, "runs")))
    for name in runs:
        folder = os.path.join(dataset, "runs", name)
        with open(os.path.join(folder, "meta.json")) as handle:
            meta = json.load(handle)
        names = [c["name"] for c in meta["inputs"]]
        (c, h, w), inputs = read_npy(os.path.join(folder, "inputs.npy"))
        _, targets = read_npy(os.path.join(folder, "targets.npy"))
        _, mask = read_npy(os.path.join(folder, "mask.npy"))
        plan = h * w
        cells = [n for n in range(plan) if mask[n] > 0 and targets[n] > 10]
        for n in rng.sample(cells, min(per_run, len(cells))):
            log_z = inputs[names.index("logScaledDistance") * plan + n]
            kb = inputs[names.index("kingeryBulmashPeak") * plan + n]
            out.append((log_z, math.log(targets[n] / kb)))
    return runs, out


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--cells", type=int, default=4000)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--sleep", type=float, default=0.0, help="seconds to wait each epoch (to test timeouts)")
    a = parser.parse_args(argv)
    rng = random.Random(a.seed)
    started = time.time()
    runs, data = samples(a.data, a.cells, rng)
    print("standin: %d runs, %d cells, Python %s on %s" % (len(runs), len(data), sys.version.split()[0],
                                                           os.uname()[1]), flush=True)
    mean_z = sum(z for z, _ in data) / len(data)
    slope, intercept, history = 0.0, 0.0, []
    for epoch in range(a.epochs):
        rng.shuffle(data)
        total = 0.0
        for z, y in data:
            error = intercept + slope * (z - mean_z) - y
            total += error * error
            intercept -= 0.01 * error
            slope -= 0.01 * error * (z - mean_z)
        history.append(total / len(data))
        print("epoch %d: loss %.4f" % (epoch + 1, history[-1]), flush=True)
        if a.sleep:
            time.sleep(a.sleep)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "model.json"), "w") as handle:
        json.dump({"form": "ln(peak / KB) = intercept + slope (ln Z - meanLogZ)", "intercept": intercept,
                   "slope": slope, "meanLogZ": mean_z}, handle, indent=1)
    with open(os.path.join(a.out, "metrics.json"), "w") as handle:
        json.dump({"runs": runs, "cells": len(data), "loss": history, "seconds": time.time() - started}, handle,
                  indent=1)
    print("standin: loss %.4f to %.4f; peak ratio to KB at the mean ln Z %.2f" % (
        history[0], history[-1], math.exp(intercept)), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
