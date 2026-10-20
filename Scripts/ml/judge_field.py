#!/usr/bin/env python3
"""Judge the learned field model beside the façade load surrogate, at the façades of held-out runs.

    python judge_field.py --data DATASET --model NAME=OUT/best.pt [--model NAME=...] [--split OUT/split.json]
        [--scenebench .build/release/scenebench] [--strips FOLDER] [--recorded FOLDER] [--inside 0.85]
        [--device cpu] [--out judged.json]

The field model (train_field.py) predicts the peak overpressure and positive impulse 2 m over the
ground on the run's plan cells; the surrogate (FacadeLoadSurrogate) predicts each façade strip's
load, a storey tall along a block's side. They meet at the ground-floor strips: on the run's 4 m
cells the air 2 m over the ground is the first layer of cells, the layer the recorder reads a
ground-floor strip's outer side from. So for each held-out run (split.json's, else every run):

- `scenebench field-surrogate`, with the run's own field-export arguments (field-runs.json), lays
  out its district again and writes the surrogate's strips with their features (cached in
  `--strips`);
- each ground-floor strip (its storey spanning 2 m over the ground) is matched to the run's plan
  cells in front of it: the air cells beside its face, along its width, in the run's mask;
- the truth is the run's own field there, the mean over those cells; the field model's is the mean
  of its predictions over the same cells; the surrogate's is its strip's; Kingery–Bulmash's is the
  incident value at the strip's distance (the field model's base) and the surrogate's base (raised
  toward reflected by the facing).

Each is judged as `scenebench surrogate-judge` and train_field.py judge: the median of predicted
over run (a ratio) and the standard deviation of its logarithm, by scaled-distance band, by
distance, by layout kind and by the strip's sight of the charge (in sight, shielded, in a street
the line runs down, facing away).

Where a `district-compare --save-loads --export-field` run of the same district is in `--recorded`
(<id>/loads; with the dataset run's top, `--height`, it is the dataset's run to the bit), the
recorder's own strips are a second truth: each strip's peak of its mean over its faces and its
first positive phase's impulse, the quantities the surrogate was fitted to. The run's field at the
strip (`runField`) is judged against them beside the predictors. On the first four such runs the
field's peak is the strip's within a few per cent; its impulse, all the positive phases, is about
1.3 times the strip's first phase (docs/learned-models.md).

CPU only (the network is small); the PyTorch venv's torch and numpy only.
"""
import argparse
import csv
import importlib.util
import json
import math
import os
import subprocess
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import train_field  # noqa: E402


def field_runs():
    spec = importlib.util.spec_from_file_location("field_runs", os.path.join(HERE, "field-runs.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BANDS = train_field.BANDS
DISTANCES = [0, 50, 100, 200, 350, 500, 700, 1000, float("inf")]


# MARK: - The surrogate's strips

def strips_for(run_id, folder, scenebench, plan, fr):
    """The surrogate's façade strips of run `run_id`, [{column: value}], made with
    `scenebench field-surrogate` if not already in `folder`."""
    path = os.path.join(folder, run_id + ".csv")
    if not os.path.exists(path):
        run = next(r for r in plan["sets"]["main"] if r["id"] == run_id)
        layout = plan["layouts"][run["layout"]]
        arguments = fr.field_arguments(run, layout, fr.inputs_for(run["layout"], layout, make=False), path + ".tmp")
        arguments[0] = "field-surrogate"
        log = os.path.join(folder, run_id + ".log")
        with open(log, "w") as handle:
            subprocess.run([scenebench] + arguments, check=True, stdout=handle, stderr=subprocess.STDOUT,
                           stdin=subprocess.DEVNULL)
        os.replace(path + ".tmp", path)
    with open(path) as handle:
        return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(handle)]


def recorded_for(run_id, folder):
    """The recorder's strips of run `run_id`, where `folder`/<id>/loads holds a `district-compare
    --save-loads` of the same district (strips.json and net.f16, the strips with their boxes):
    {box key: (peak Pa, first-phase impulse Pa s)}, as `scenebench surrogate-extract` reads them;
    None without one."""
    loads = os.path.join(folder, run_id, "loads")
    if not os.path.exists(os.path.join(loads, "strips.json")):
        return None
    with open(os.path.join(loads, "strips.json")) as handle:
        index = json.load(handle)
    values = np.fromfile(os.path.join(loads, "net.f16"), dtype="<f2").astype(np.float64) * (index.get("scalePa") or 1)
    found = {}
    for strip in index["strips"]:
        if strip.get("low") is None:
            continue
        net = values[strip["first"]:strip["first"] + strip["count"]]
        found[box_key(strip["axis"], strip["outward"], strip["low"], strip["high"])] = (
            float(net.max()) if net.size else 0.0, first_impulse(net, strip["binS"]))
    return found


def box_key(axis, outward, low, high):
    return (int(axis), int(outward)) + tuple(int(round(10 * v)) for v in list(low) + list(high))


def first_impulse(net, bin_s):
    """The impulse of a net history's first positive phase, Pa s, as SurrogateBench.firstImpulse:
    from the start to where it first falls below nothing after reaching half its peak."""
    if net.size == 0 or net.max() <= 0:
        return 0.0
    half = 0.5 * net.max()
    risen = np.maximum.accumulate(net >= half)
    after = np.nonzero(risen & (net < 0))[0]
    end = after[0] if after.size else net.size
    return float(np.maximum(net[:end], 0).sum() * bin_s)


def front_cells(strip, dx, shape):
    """The plan cells (rows, columns) of air beside `strip`'s outer face, along its width: the first
    cells whose centres lie beyond the face, over the cells whose centres its width covers (its
    middle one if it is narrower than a cell)."""
    axis, outward = int(strip["axis"]), int(strip["outward"])
    low = (strip["x0"], strip["y0"])
    high = (strip["x1"], strip["y1"])
    face = high[axis] if outward > 0 else low[axis]
    first = int(math.ceil(face / dx - 0.5))
    across = first if outward > 0 else first - 1
    other = 1 - axis
    a = int(math.ceil(low[other] / dx - 0.5))
    b = int(math.ceil(high[other] / dx - 0.5)) - 1
    if b < a:
        a = b = int(math.floor(0.5 * (low[other] + high[other]) / dx))
    along = np.arange(a, b + 1)
    if axis == 0:
        columns, rows = np.full_like(along, across), along
    else:
        rows, columns = np.full_like(along, across), along
    keep = (rows >= 0) & (rows < shape[0]) & (columns >= 0) & (columns < shape[1])
    return rows[keep], columns[keep]


# MARK: - The field model

def load_model(path, device):
    state = torch.load(path, map_location="cpu", weights_only=False)
    args = argparse.Namespace(**state["args"])
    model = train_field.build(args.model, args)
    model.load_state_dict(state["model"])
    model.to(device).eval()
    return model, state


def predict(model, state, run, device):
    """The model's log peak and log impulse over the run's whole plan, (2, H, W)."""
    stats = state["stats"]
    mean = torch.tensor(stats["mean"]).view(1, -1, 1, 1)
    std = torch.tensor(stats["std"]).view(1, -1, 1, 1)
    x = (torch.from_numpy(run["x"])[None] - mean) / std
    h, w = x.shape[-2:]
    multiple = model.multiple
    x = F.pad(x, (0, (-w) % multiple, 0, (-h) % multiple), mode="replicate").to(device)
    with torch.no_grad():
        out = model(x).float()[0, :, :h, :w].cpu().numpy()
    return out + (run["kb"] if state.get("residual", True) else 0)


# MARK: - Judging

def stats(errors):
    e = np.asarray(errors)
    return {"ratio": float(np.exp(np.median(e))), "logSD": float(e.std())} if e.size else None


def group_table(rows, predictors, key, order):
    """For each group of `rows` by `key` (in `order`), the count and each predictor's peak and
    impulse ratio and log-SD."""
    table = []
    for name in order:
        chosen = [r for r in rows if key(r) == name] if name != "all" else rows
        if not chosen:
            continue
        entry = {"group": name, "strips": len(chosen)}
        for p in predictors:
            entry[p] = {q: stats([math.log(r[p][q] / r["truth"][q]) for r in chosen]) for q in ("peak", "impulse")}
        table.append(entry)
    return table


def band_of(value, edges, unit=""):
    for lo, hi in zip(edges, edges[1:]):
        if lo <= value < hi:
            return "%g-%g%s" % (lo, hi, unit) if hi != float("inf") else ">%g%s" % (lo, unit)
    return None


def sight_of(r):
    if r["cos"] < 0:
        return "facing away"
    if r["canyon"] > 0:
        return "street to the charge"
    if r["crossed"] == 0:
        return "in sight, facing"
    return "shielded, 1-3 crossed" if r["crossed"] <= 3 else "shielded, 4+ crossed"


def kind_of(layout):
    return "beirut" if layout.startswith("beirut") else layout.split("-")[1] if layout.startswith("made-") else layout


def print_table(title, table, predictors):
    print("\n%s" % title)
    head = "  %-24s %7s" % ("", "strips") + "".join("  %-21s" % p for p in predictors)
    print(head)
    print("  %-24s %7s" % ("", "") + "".join("  %-21s" % "peak      impulse" for _ in predictors))
    for row in table:
        cells = []
        for p in predictors:
            pk, im = row[p]["peak"], row[p]["impulse"]
            cells.append("  %.2f/%.2f  %.2f/%.2f" % (pk["ratio"], pk["logSD"], im["ratio"], im["logSD"]))
        print("  %-24s %7d" % (row["group"], row["strips"]) + "".join(cells))
    sys.stdout.flush()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--data", required=True)
    parser.add_argument("--model", action="append", required=True, help="NAME=path/to/best.pt")
    parser.add_argument("--split", help="split.json naming the held-out runs (default: the first model's)")
    parser.add_argument("--scenebench", default=os.path.join(REPOSITORY, ".build", "release", "scenebench"))
    parser.add_argument("--strips", default="/Volumes/StudioData/bombcad/ml/judge/strips")
    parser.add_argument("--inside", type=float, default=0.85,
                        help="only strips within this share of the half side from the domain's middle")
    parser.add_argument("--recorded", default="/Volumes/StudioData/bombcad/ml/judge/compare",
                        help="folder of district-compare runs of held-out runs (<id>/loads), for the recorder's strips")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--out")
    args = parser.parse_args(argv)

    models = []
    for spec in args.model:
        name, path = spec.split("=", 1)
        model, state = load_model(path, torch.device(args.device))
        models.append((name, model, state))
    split = args.split or os.path.join(os.path.dirname(args.model[0].split("=", 1)[1]), "split.json")
    with open(split) as handle:
        held = json.load(handle)["heldOut"]
    fr = field_runs()
    with open(fr.LIST) as handle:
        plan = json.load(handle)
    os.makedirs(args.strips, exist_ok=True)
    predictors = [m[0] for m in models] + ["surrogate", "kb", "kbFacing"]

    rows = []
    began = time.time()
    for run_id in held:
        run = train_field.load_run(os.path.join(args.data, "runs", run_id))
        if run is None:
            print("judge_field: %s is not in the dataset, or was unstable; left out" % run_id)
            continue
        meta = run["meta"]
        dx = meta["cellSizeM"]
        targets = np.exp(run["y"])
        mask = run["mask"]
        fields = {name: np.exp(predict(model, state, run, torch.device(args.device))) for name, model, state in models}
        strips = strips_for(run_id, args.strips, args.scenebench, plan, fr)
        cx, cy = meta["charge"]["positionM"][:2]
        half = 0.5 * meta["domainM"][0]
        middle = (0.5 * meta["domainM"][0], 0.5 * meta["domainM"][1])
        root = meta["charge"]["massKg"] ** (1 / 3)
        recorded = recorded_for(run_id, args.recorded) if args.recorded else None
        used = 0
        for s in strips:
            # The ground-floor strip: its storey spans the field's 2 m over the ground.
            if not (s["z0"] <= s["ground"] + meta["heightAboveGroundM"] <= s["z1"]):
                continue
            centre = (0.5 * (s["x0"] + s["x1"]), 0.5 * (s["y0"] + s["y1"]))
            if max(abs(centre[0] - middle[0]), abs(centre[1] - middle[1])) > args.inside * half:
                continue
            r, c = front_cells(s, dx, mask.shape)
            keep = mask[r, c]
            if not keep.any():
                continue
            r, c = r[keep], c[keep]
            row = {"run": run_id, "layout": run["layout"], "kind": kind_of(run["layout"]),
                   "z": s["distance"] / root, "distance": s["distance"], "cos": s["cos"],
                   "crossed": s["crossed"], "canyon": s["canyon"], "outside": s["outside"], "cells": int(r.size),
                   "truth": {"peak": float(targets[0, r, c].mean()), "impulse": float(targets[1, r, c].mean())},
                   "surrogate": {"peak": s["peak"], "impulse": s["impulse"]},
                   "kb": {"peak": s["kbpeak"], "impulse": s["kbimpulse"]},
                   "kbFacing": {"peak": s["basepeak"], "impulse": s["baseimpulse"]}}
            for name, field in fields.items():
                row[name] = {"peak": float(field[0, r, c].mean()), "impulse": float(field[1, r, c].mean())}
            if recorded is not None:
                # The recorder's strip of the same box: its peak of the mean over its faces and its
                # first positive phase.
                found = recorded.get(box_key(s["axis"], s["outward"], (s["x0"], s["y0"], s["z0"]),
                                             (s["x1"], s["y1"], s["z1"])))
                if found and found[0] > 0 and found[1] > 0:
                    row["recorded"] = {"peak": found[0], "impulse": found[1]}
            if all(row[p][q] > 0 for p in predictors + ["truth"] for q in ("peak", "impulse")):
                rows.append(row)
                used += 1
        print("judge_field: %s (%s), %d of %d strips judged, %.0f s" % (
            run_id, run["layout"], used, len(strips), time.time() - began))
        sys.stdout.flush()

    zbands = ["all"] + ["%g-%g" % (lo, hi) if hi != float("inf") else ">%g" % lo for lo, hi in zip(BANDS, BANDS[1:])]
    dbands = ["%g-%g m" % (lo, hi) if hi != float("inf") else ">%g m" % lo for lo, hi in zip(DISTANCES, DISTANCES[1:])]
    kinds = ["beirut", "grid", "industrial", "mixed", "perimeter", "towers"]
    sights = ["in sight, facing", "shielded, 1-3 crossed", "shielded, 4+ crossed", "street to the charge",
              "facing away"]
    matters = [r for r in rows if r["kind"] == "beirut" and 50 <= r["distance"] < 700]
    result = {
        "made": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "data": os.path.abspath(args.data), "models": args.model, "split": os.path.abspath(split),
        "heldOut": held, "inside": args.inside, "strips": len(rows),
        "byScaledDistance": group_table(rows, predictors, lambda r: band_of(r["z"], BANDS), zbands),
        "byDistance": group_table(rows, predictors, lambda r: band_of(r["distance"], DISTANCES, " m"), dbands),
        "byKind": group_table(rows, predictors, lambda r: r["kind"], kinds),
        "bySight": group_table(rows, predictors, sight_of, sights),
        "beirut50to700": group_table(matters, predictors, sight_of, ["all"] + sights),
        "beirut50to700ByDistance": group_table(
            matters, predictors, lambda r: band_of(r["distance"], DISTANCES, " m"), dbands),
        "faceOnOpen": group_table([r for r in rows if r["cos"] > 0.7 and r["crossed"] == 0], predictors,
                                  lambda r: band_of(r["z"], BANDS), zbands),
    }
    # Against the recorder's strips, where a district-compare run of the same district gives them:
    # the field's own value at the strip (the run's cells in front of it) beside the predictors, to
    # show what judging against the field rather than the strip moves.
    against = [dict(r, truth=r["recorded"], runField=r["truth"]) for r in rows if "recorded" in r]
    if against:
        result["recordedStrips"] = len(against)
        result["recordedRuns"] = sorted({r["run"] for r in against})
        result["recordedByScaledDistance"] = group_table(
            against, predictors + ["runField"], lambda r: band_of(r["z"], BANDS), zbands)
        result["recordedBySight"] = group_table(against, predictors + ["runField"], sight_of, ["all"] + sights)
        result["recordedByKind"] = group_table(against, predictors + ["runField"], lambda r: r["kind"], kinds)
        result["recordedBeirut50to700"] = group_table(
            [r for r in against if r["kind"] == "beirut" and 50 <= r["distance"] < 700],
            predictors + ["runField"], sight_of, ["all"] + sights)
    print("\nRatio / log-SD of predicted over the run, peak then impulse, for: " + ", ".join(predictors))
    print_table("By scaled distance, Z m/kg^(1/3)", result["byScaledDistance"], predictors)
    print_table("By distance", result["byDistance"], predictors)
    print_table("By layout kind", result["byKind"], predictors)
    print_table("By sight of the charge", result["bySight"], predictors)
    print_table("Beirut, 50-700 m, by sight", result["beirut50to700"], predictors)
    print_table("Beirut, 50-700 m, by distance", result["beirut50to700ByDistance"], predictors)
    print_table("In sight and facing it (cos > 0.7), by Z", result["faceOnOpen"], predictors)
    if against:
        print("\nAgainst the recorder's strips (%d, runs %s): runField is the run's own field there" % (
            len(against), ", ".join(result["recordedRuns"])))
        print_table("By scaled distance", result["recordedByScaledDistance"], predictors + ["runField"])
        print_table("By sight of the charge", result["recordedBySight"], predictors + ["runField"])
        print_table("By layout kind", result["recordedByKind"], predictors + ["runField"])
        print_table("Beirut, 50-700 m, by sight", result["recordedBeirut50to700"], predictors + ["runField"])
    if args.out:
        with open(args.out, "w") as handle:
            json.dump(result, handle, indent=1)
        with open(os.path.splitext(args.out)[0] + "-strips.json", "w") as handle:
            json.dump(rows, handle)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
