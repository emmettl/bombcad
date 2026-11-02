#!/usr/bin/env python3
"""Train the live blast wave's learned refinement: corrections to its peak, arrival and impulse.

    python train_live_wave.py pack --pairs PAIRS --out DATASET [--exclude-layouts beirut]
    python train_live_wave.py --data DATASET --out OUT [--epochs 60] [--steps 120] [--batch 16]
        [--crop 192] [--width 16] [--depth 4] [--validate-layouts made-*-s6] [--resume auto|PATH|none]
        [--near-weight 4 --near-m 200] [--device auto] [--amp auto|on|off]

The live wave (Sources/BlastModel/LiveWave.swift; docs/live-wave.md) gives each cell of a
district's plan the front's arrival, its peak and a Friedlander pulse from the shortest path round
and over buildings and Kingery-Bulmash's fits along it. This network corrects it towards BombCAD's
own 4 m district runs (emmettl/bombcad-work#115): from the plan and the wave's own fields, the logs
of the run's peak, arrival and positive impulse over the wave's. A correction of nothing is the
wave as it was, and the head starts at nothing.

PAIRS is what `blastmodel live-wave-features` writes: runs/<id>/c<k>/{features,targets,sight}.npy
and meta.json, on the run's own 4 m plan (c1) and on it coarsened twice (c2, the cells the app
works on while a large district's charge is dragged). `pack` turns them into one compressed
float16 file a run (runs/<id>.npz) and leaves out the layouts named, so that Beirut's runs, held
out, never leave the Studio. Training reads the packed dataset.

The network is train_field.py's U-Net without its group norms (`Block(norm=False)`): with
standardised inputs it needs none, and without them a cell's correction depends only on the plan
about it, so that crops in training and the whole plan in the app agree. BlastCore's
`LearnedFieldNetwork` runs it from the `.bcfw` file export_live_wave_weights.py writes.

The loss is a Huber loss on each target's residual over its own scale (the peak's and impulse's
0.2, the arrival's 0.03), over the cells the run has it; cells nearer the charge than `--near-m`
weigh up to `--near-weight` times more, as (near-m / distance) held between 1 and it. Validation
runs (`--validate-layouts`) are not trained on; the epoch kept in best.pt has the least loss on
them. Each epoch they are judged, on their full plans at both cell sizes, as `live-wave-judge`
judges: the share of peaks within x1.25 in sight and shielded, within 100 m, and the arrivals'
mean error beyond 200 m, the wave before and after.
"""
import argparse
import fnmatch
import json
import math
import os
import random
import sys
import time

import numpy as np

INPUTS = ["height", "footprint", "ground", "logPathScaledDistance", "pathExcess", "logStraightScaledDistance",
          "logLivePeak", "logLiveScaledArrival", "cellM"]
OUTPUTS = ["logPeakRatio", "logArrivalRatio", "logImpulseRatio"]
SCALES = [0.2, 0.03, 0.2]


# MARK: - Packing (on the Studio, NumPy only)

def pack(args):
    """runs/<id>/c<k>/*.npy into runs/<id>.npz, float16, compressed; the layouts excluded left out."""
    excluded = [p for p in (args.exclude_layouts or "").split(",") if p]
    os.makedirs(os.path.join(args.out, "runs"), exist_ok=True)
    index = []
    for run in sorted(os.listdir(os.path.join(args.pairs, "runs"))):
        folder = os.path.join(args.pairs, "runs", run)
        levels = sorted(name for name in os.listdir(folder) if name.startswith("c"))
        metas = {}
        arrays = {}
        for level in levels:
            path = os.path.join(folder, level, "meta.json")
            if not os.path.exists(path):
                continue
            with open(path) as handle:
                meta = json.load(handle)
            if meta["inputs"] != INPUTS or meta["targets"] != OUTPUTS:
                raise SystemExit("train_live_wave: %s has inputs %s" % (path, meta["inputs"]))
            metas[level] = meta
            for name in ("features", "targets", "sight"):
                arrays["%s_%s" % (level, name)] = np.load(os.path.join(folder, level, name + ".npy")).astype(np.float16)
        if not metas:
            continue
        meta = next(iter(metas.values()))
        if any(fnmatch.fnmatchcase(meta["layout"], p) for p in excluded):
            continue
        target = os.path.join(args.out, "runs", run + ".npz")
        np.savez_compressed(target, **arrays)
        index.append({"id": run, "layout": meta["layout"], "massKg": meta["massKg"], "levels": sorted(metas),
                      "cells": {level: [m["rows"], m["columns"]] for level, m in metas.items()}})
        print("packed %s (%s): %.1f MB" % (run, ", ".join(sorted(metas)), os.path.getsize(target) / 1e6), flush=True)
    with open(os.path.join(args.out, "dataset.json"), "w") as handle:
        json.dump({"format": "bombcad-live-wave-dataset-1", "inputs": INPUTS, "outputs": OUTPUTS,
                   "excludedLayouts": excluded, "runs": index}, handle, indent=1)
    print("%d runs packed into %s" % (len(index), args.out))
    return 0


# MARK: - Data

def load(data):
    with open(os.path.join(data, "dataset.json")) as handle:
        index = json.load(handle)
    runs = []
    for entry in index["runs"]:
        packed = np.load(os.path.join(data, "runs", entry["id"] + ".npz"))
        for level in entry["levels"]:
            x = packed[level + "_features"].astype(np.float32)
            y = packed[level + "_targets"].astype(np.float32)
            sight = packed[level + "_sight"].astype(np.float32)
            root = entry["massKg"] ** (1 / 3)
            distance = np.exp(x[5]) * root
            runs.append({"id": entry["id"], "layout": entry["layout"], "level": level, "x": x, "y": y,
                         "sight": sight, "distance": distance.astype(np.float32)})
    return runs


def statistics(runs):
    sums = np.zeros(len(INPUTS))
    squares = np.zeros(len(INPUTS))
    count = 0
    for run in runs:
        x = run["x"].reshape(len(INPUTS), -1).astype(np.float64)
        sums += x.sum(1)
        squares += (x * x).sum(1)
        count += x.shape[1]
    mean = sums / count
    std = np.sqrt(np.maximum(squares / count - mean * mean, 0))
    std = np.where(std > 1e-6, std, 1.0)
    return {"mean": mean.tolist(), "std": std.tolist()}


def weights_for(run, near_weight, near_m):
    return np.clip(near_m / np.maximum(run["distance"], 1.0), 1.0, near_weight).astype(np.float32)


# MARK: - The network

def build_modules():
    import torch.nn as nn
    import torch.nn.functional as F
    import torch

    class Block(nn.Module):
        """train_field.py's Block: two 3 x 3 convolutions, each followed by GELU; with `norm`,
        a group norm between, as there. The indices 0 and 3 are the convolutions either way."""

        def __init__(self, a, b, norm=False):
            super().__init__()
            def normal(c):
                return nn.GroupNorm(math.gcd(8, c), c) if norm else nn.Identity()
            self.body = nn.Sequential(nn.Conv2d(a, b, 3, padding=1), normal(b), nn.GELU(),
                                      nn.Conv2d(b, b, 3, padding=1), normal(b), nn.GELU())

        def forward(self, x):
            return self.body(x)

    class UNet(nn.Module):
        """train_field.py's U-Net: `depth` halvings, `width` channels at the top doubling at each."""

        def __init__(self, inputs, outputs, width=16, depth=4, norm=False):
            super().__init__()
            widths = [width * 2 ** n for n in range(depth + 1)]
            self.down = nn.ModuleList([Block(inputs, widths[0], norm)] +
                                      [Block(widths[n], widths[n + 1], norm) for n in range(depth)])
            self.up = nn.ModuleList([Block(widths[n + 1] + widths[n], widths[n], norm) for n in reversed(range(depth))])
            self.head = nn.Conv2d(widths[0], outputs, 1)
            nn.init.zeros_(self.head.weight)
            nn.init.zeros_(self.head.bias)
            self.multiple = 2 ** depth

        def forward(self, x):
            skips = []
            for n, block in enumerate(self.down):
                x = block(x if n == 0 else F.max_pool2d(x, 2))
                skips.append(x)
            skips.pop()
            for block in self.up:
                skip = skips.pop()
                x = F.interpolate(x, size=skip.shape[-2:], mode="bilinear", align_corners=False)
                x = block(torch.cat([x, skip], dim=1))
            return self.head(x)

    return UNet


def device_for(name):
    import torch
    if name == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")
    return torch.device(name)


def precision(device, amp):
    import torch
    if amp == "off" or (amp == "auto" and device.type == "cpu"):
        return False, torch.float32
    if device.type == "cuda":
        return True, torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    if device.type == "mps":
        # float16 on MPS does not train (docs/learned-models.md): float32 there unless asked.
        return amp == "on", torch.float16
    return True, torch.bfloat16


# MARK: - Training

def crops(runs, batch, crop, stats, near_weight, near_m, rng):
    """A batch of random crops, each turned by one of the square's eight symmetries."""
    mean = np.array(stats["mean"], np.float32)[:, None, None]
    std = np.array(stats["std"], np.float32)[:, None, None]
    xs, ys, ws = [], [], []
    for _ in range(batch):
        run = runs[rng.randrange(len(runs))]
        h, w = run["y"].shape[-2:]
        size = min(crop, h, w)
        i = rng.randrange(h - size + 1)
        j = rng.randrange(w - size + 1)
        x = (run["x"][:, i:i + size, j:j + size] - mean) / std
        y = run["y"][:, i:i + size, j:j + size]
        wt = run["weight"][i:i + size, j:j + size]
        k = rng.randrange(4)
        flip = rng.randrange(2)
        x, y, wt = (np.rot90(a, k, axes=(-2, -1)) for a in (x, y, wt))
        if flip:
            x, y, wt = (a[..., ::-1] for a in (x, y, wt))
        xs.append(np.ascontiguousarray(x))
        ys.append(np.ascontiguousarray(y))
        ws.append(np.ascontiguousarray(wt))
    return np.stack(xs), np.stack(ys), np.stack(ws)


def loss_of(out, y, w, delta=3.0):
    """The Huber loss of each target's residual over its scale, weighted, over the cells it has."""
    import torch
    import torch.nn.functional as F
    scales = torch.tensor(SCALES, device=out.device).view(1, -1, 1, 1)
    have = torch.isfinite(y)
    target = torch.where(have, y, torch.zeros_like(y))
    residual = (out.float() - target) / scales
    loss = F.huber_loss(residual, torch.zeros_like(residual), reduction="none", delta=delta)
    weight = w[:, None] * have.float()
    return (loss * weight).sum() / weight.sum().clamp_min(1.0)


def predict(model, run, stats, device, autocast, dtype):
    import torch
    mean = torch.tensor(stats["mean"]).view(1, -1, 1, 1)
    std = torch.tensor(stats["std"]).view(1, -1, 1, 1)
    x = (torch.from_numpy(run["x"])[None] - mean) / std
    h, w = x.shape[-2:]
    multiple = model.multiple
    x = torch.nn.functional.pad(x, (0, (-w) % multiple, 0, (-h) % multiple), mode="replicate").to(device)
    with torch.no_grad(), torch.autocast(device_type=device.type, dtype=dtype, enabled=autocast):
        out = model(x).float()[0, :, :h, :w].cpu().numpy()
    return out


def judge(model, runs, stats, device, autocast, dtype, near_weight, near_m):
    """The validation runs judged as live-wave-judge judges, before (the wave) and after."""
    import torch
    totals = {"loss": 0.0, "weight": 0.0}
    shares = {}
    for run in runs:
        out = predict(model, run, stats, device, autocast, dtype)
        y = run["y"]
        with torch.no_grad():
            totals["loss"] += float(loss_of(torch.from_numpy(out)[None], torch.from_numpy(y)[None],
                                            torch.from_numpy(run["weight"])[None])) * 1.0
            totals["weight"] += 1.0
        limit = math.log(1.25)
        peak = y[0]
        have = np.isfinite(peak)
        for name, cells in (("sight", have & (run["sight"] > 0)), ("shielded", have & (run["sight"] == 0)),
                            ("near100", have & (run["distance"] < 100))):
            if not cells.any():
                continue
            entry = shares.setdefault(run["level"] + ":" + name, [0, 0, 0])
            entry[0] += int((np.abs(peak[cells]) < limit).sum())
            entry[1] += int((np.abs(peak[cells] - out[0][cells]) < limit).sum())
            entry[2] += int(cells.sum())
        arrival = y[1]
        for name, cells in (("arrival>200", np.isfinite(arrival) & (run["distance"] >= 200)),
                            ("arrival<200", np.isfinite(arrival) & (run["distance"] < 200))):
            if not cells.any():
                continue
            entry = shares.setdefault(run["level"] + ":" + name, [0.0, 0.0, 0])
            # The mean error of the wave's arrival over the run's: |e^(-t) - 1| before, after.
            entry[0] += float(np.abs(np.exp(-arrival[cells]) - 1).sum())
            entry[1] += float(np.abs(np.exp(out[1][cells] - arrival[cells]) - 1).sum())
            entry[2] += int(cells.sum())
        impulse = y[2]
        cells = np.isfinite(impulse)
        entry = shares.setdefault(run["level"] + ":impulse", [0, 0, 0])
        entry[0] += int((np.abs(impulse[cells]) < limit).sum())
        entry[1] += int((np.abs(impulse[cells] - out[2][cells]) < limit).sum())
        entry[2] += int(cells.sum())
    result = {"loss": totals["loss"] / max(totals["weight"], 1)}
    for key, (before, after, count) in shares.items():
        result[key] = {"before": before / max(count, 1), "after": after / max(count, 1), "cells": count}
    return result


def train(args):
    import torch
    torch.manual_seed(args.seed)
    rng = random.Random(args.seed)
    device = device_for(args.device)
    autocast, dtype = precision(device, args.amp)
    os.makedirs(args.out, exist_ok=True)
    runs = load(args.data)
    patterns = [p for p in args.validate_layouts.split(",") if p]
    validating = [run for run in runs if any(fnmatch.fnmatchcase(run["layout"], p) for p in patterns)]
    held = {id(run) for run in validating}
    training = [run for run in runs if id(run) not in held]
    if not training or not validating:
        raise SystemExit("train_live_wave: %d training and %d validation plans" % (len(training), len(validating)))
    for run in runs:
        run["weight"] = weights_for(run, args.near_weight, args.near_m)
    checkpoint_path = os.path.join(args.out, "checkpoint.pt")
    resume = checkpoint_path if args.resume == "auto" and os.path.exists(checkpoint_path) else (
        None if args.resume in ("auto", "none") else os.path.expanduser(args.resume))
    state = torch.load(resume, map_location="cpu", weights_only=False) if resume else None
    stats = state["stats"] if state else statistics(training)
    UNet = build_modules()
    model = UNet(len(INPUTS), len(OUTPUTS), args.width, args.depth).to(device)
    optimiser = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    total = args.epochs * args.steps

    def rate(step):
        warm = min(1.0, (step + 1) / 200)
        return warm * 0.5 * (1 + math.cos(math.pi * min(step, total) / total))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimiser, rate)
    history, start, best = [], 0, float("inf")
    if state:
        model.load_state_dict(state["model"])
        optimiser.load_state_dict(state["optimiser"])
        scheduler.load_state_dict(state["scheduler"])
        history, start, best = state["history"], state["epoch"] + 1, state["best"]
        rng.setstate(state["rng"])
        print("train_live_wave: resuming at epoch %d" % start, flush=True)
    parameters = sum(p.numel() for p in model.parameters())
    print("train_live_wave: %d training plans, %d validation (%s), %d parameters, %s %s" % (
        len(training), len(validating), ",".join(patterns), parameters, device, dtype if autocast else "float32"),
        flush=True)
    for epoch in range(start, args.epochs):
        model.train()
        clock = time.time()
        losses = []
        for _ in range(args.steps):
            x, y, w = crops(training, args.batch, args.crop, stats, args.near_weight, args.near_m, rng)
            x, y, w = (torch.from_numpy(a).to(device) for a in (x, y, w))
            with torch.autocast(device_type=device.type, dtype=dtype, enabled=autocast):
                out = model(x)
            loss = loss_of(out, y, w)
            optimiser.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimiser.step()
            scheduler.step()
            losses.append(float(loss.detach()))
        model.eval()
        judged = judge(model, validating, stats, device, autocast, dtype, args.near_weight, args.near_m)
        entry = {"epoch": epoch, "trainLoss": float(np.mean(losses)), "validation": judged,
                 "seconds": time.time() - clock}
        history.append(entry)
        line = "epoch %d: train %.4f, validation %.4f" % (epoch, entry["trainLoss"], judged["loss"])
        for key in ("c1:sight", "c1:shielded", "c1:near100", "c1:arrival>200", "c2:shielded"):
            if key in judged:
                line += "; %s %.3f -> %.3f" % (key, judged[key]["before"], judged[key]["after"])
        print(line + " (%.0f s)" % entry["seconds"], flush=True)
        snapshot = {"model": model.state_dict(), "optimiser": optimiser.state_dict(),
                    "scheduler": scheduler.state_dict(), "epoch": epoch, "history": history, "stats": stats,
                    "rng": rng.getstate(), "best": best, "args": vars(args), "inputs": INPUTS, "outputs": OUTPUTS,
                    "validation": sorted({run["id"] for run in validating}),
                    "training": sorted({run["id"] for run in training})}
        if judged["loss"] < best:
            best = snapshot["best"] = judged["loss"]
            torch.save(snapshot, os.path.join(args.out, "best.pt"))
        torch.save(snapshot, checkpoint_path + ".tmp")
        os.replace(checkpoint_path + ".tmp", checkpoint_path)
        with open(os.path.join(args.out, "metrics.json"), "w") as handle:
            json.dump({"history": history, "best": best, "parameters": parameters}, handle, indent=1)
    return 0


def main(argv):
    if argv and argv[0] == "pack":
        parser = argparse.ArgumentParser(description="pack live-wave-features pairs")
        parser.add_argument("--pairs", required=True)
        parser.add_argument("--out", required=True)
        parser.add_argument("--exclude-layouts", default="beirut")
        return pack(parser.parse_args(argv[1:]))
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--steps", type=int, default=120)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--crop", type=int, default=192)
    parser.add_argument("--width", type=int, default=16)
    parser.add_argument("--depth", type=int, default=4)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--near-weight", type=float, default=4.0)
    parser.add_argument("--near-m", type=float, default=200.0)
    parser.add_argument("--validate-layouts", default="made-*-s6")
    parser.add_argument("--resume", default="auto")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--amp", default="auto")
    parser.add_argument("--seed", type=int, default=115)
    return train(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
