#!/usr/bin/env python3
"""Train the learned field model: peak overpressure and impulse over a district from its plan.

    python train_field.py --data DATASET --out OUT [--model unet|fno] [--epochs 40] [--batch 8]
        [--crop 256] [--holdout 0.2 | --holdout-runs id,id] [--split-by run|layout] [--device auto]
        [--amp auto|on|off] [--resume auto|PATH|none] [--width 32] [--depth 4] [--modes 24]
    python train_field.py --estimate [--grid 256,512] [--batch 8] [--model unet,fno] [--gpu rtx3080ti]

DATASET is what `Scripts/ml/field-runs.py run` writes: runs/<id>/inputs.npy, targets.npy, mask.npy
and meta.json for each run (docs/learned-models.md). The network sees, on the run's plan grid, the
buildings' heights over the ground, their footprints, the ground, the scaled distance from the
charge and Kingery–Bulmash's incident peak and impulse there, and predicts the natural logs of the
run's peak overpressure (Pa) and positive impulse (Pa s) 2 m over the ground, as corrections to
Kingery–Bulmash's (`--no-residual` predicts them outright). The loss is the squared error of the
logs over the mask (air at that height, away from the side faces).

Training draws random crops from the training runs, each turned by one of the eight flips and
rotations of the square (the plan has no preferred direction). Runs are held out whole, chosen by
`--seed`, and judged on their full maps after each epoch: by bands of scaled distance, the median
of predicted over run (as a ratio) and the standard deviation of its logarithm, as
`scenebench surrogate-judge` judges the façade surrogate; Kingery–Bulmash alone is judged the same
way for reference. Mixed precision on CUDA (bfloat16 where supported, else float16 with a scaler)
and on MPS (float16); CPU runs in float32. A checkpoint is written each epoch and the best by
held-out loss kept; `--resume auto` (the default) carries on from OUT/checkpoint.pt.

`--estimate` prints, for each model and grid, the parameters, the memory a training step takes
(activations by forward hooks, weights, gradients and Adam's moments) and its time: measured on
this machine's device, and estimated for the PCs' 12 GB cards from the step's arithmetic and
memory traffic at a stated share of their peaks. It needs no dataset.
"""
import argparse
import json
import math
import os
import random
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# The PCs' GPUs (and the Studio's, for comparison): memory, dense float16 tensor throughput with
# float32 accumulation (what autocast's matrix products use), and memory bandwidth.
GPUS = {
    "rtx3080ti": {"name": "RTX 3080 Ti (desktop)", "memGB": 12, "tflops": 34.1, "bandwidthGBs": 912},
    "rtx4080laptop": {"name": "RTX 4080 Laptop", "memGB": 12, "tflops": 49.5, "bandwidthGBs": 432},
}
# The shares of those peaks a convolutional network's training step reaches, and what CUDA's
# context and cuDNN's workspace take besides PyTorch's tensors.
EFFICIENCY = {"compute": 0.35, "bandwidth": 0.6, "overheadGB": 1.0}
BANDS = [0, 3, 5, 7, 10, 14, 20, 28, 40, float("inf")]
INPUTS = ["height", "footprint", "ground", "logScaledDistance", "logKingeryBulmashPeak", "logKingeryBulmashImpulse"]


# MARK: - Data

def load_runs(folder, only=None):
    """[{id, layout, x (C, H, W) float32 features before standardising, y (2, H, W) log targets,
    kb (2, H, W) log Kingery–Bulmash, mask (H, W), z (H, W) scaled distance}] of a dataset (the
    runs named in `only`, if given)."""
    root = os.path.join(folder, "runs")
    runs = []
    for name in sorted(os.listdir(root)):
        if only is not None and name not in only:
            continue
        run = load_run(os.path.join(root, name))
        if run:
            runs.append(run)
    return runs


def load_run(path):
    """One run of a dataset (as `load_runs`), or None if it is unfinished or was unstable."""
    try:
        with open(os.path.join(path, "meta.json")) as handle:
            meta = json.load(handle)
    except (OSError, ValueError):
        return None
    if not meta.get("stable", False):
        return None
    raw = np.load(os.path.join(path, "inputs.npy"))
    targets = np.load(os.path.join(path, "targets.npy"))
    mask = np.load(os.path.join(path, "mask.npy")) > 0
    names = [c["name"] for c in meta["inputs"]]
    channel = {n: raw[names.index(n)] for n in names}
    height = channel["height"]
    kb = np.stack([np.log(np.maximum(channel["kingeryBulmashPeak"], 1.0)),
                   np.log(np.maximum(channel["kingeryBulmashImpulse"], 1e-6))])
    x = np.stack([height, (height > 0).astype(np.float32), channel["ground"], channel["logScaledDistance"],
                  kb[0], kb[1]]).astype(np.float32)
    # Peaks under 10 Pa and impulses under 1 mPa s are noise, not targets.
    mask &= (targets[0] > 10) & (targets[1] > 1e-3)
    y = np.log(np.maximum(targets, 1e-6)).astype(np.float32)
    return {"id": meta["id"], "layout": meta.get("layout") or meta["id"], "x": x, "y": y,
            "kb": kb.astype(np.float32), "mask": mask, "z": np.exp(channel["logScaledDistance"]),
            "meta": meta}


def split(runs, holdout, holdout_runs, by, seed):
    """The held-out runs' ids: those named, or a share of the runs (or of the layouts, all runs of
    a layout together) drawn with `seed`."""
    if holdout_runs:
        held = set(holdout_runs)
    else:
        groups = sorted({run["id"] if by == "run" else run["layout"] for run in runs})
        rng = random.Random(seed)
        rng.shuffle(groups)
        count = max(1, int(round(holdout * len(groups)))) if len(groups) > 1 else 0
        chosen = set(groups[:count])
        held = {run["id"] for run in runs if (run["id"] if by == "run" else run["layout"]) in chosen}
    return sorted(held)


def statistics(runs):
    """Each input channel's mean and standard deviation over the training runs' cells."""
    stacked = np.concatenate([run["x"].reshape(run["x"].shape[0], -1) for run in runs], axis=1)
    mean = stacked.mean(axis=1)
    std = stacked.std(axis=1)
    std[std < 1e-6] = 1.0
    # The footprint stays 0 or 1.
    mean[1], std[1] = 0.0, 1.0
    return {"mean": mean.tolist(), "std": std.tolist()}


def dihedral(tensors, k, flip):
    """Each of `tensors` (..., H, W) turned k quarter turns and, with `flip`, mirrored: the eight
    symmetries of the square."""
    out = []
    for t in tensors:
        t = torch.rot90(t, k, dims=(-2, -1))
        out.append(torch.flip(t, dims=(-1,)) if flip else t)
    return out


class Crops:
    """Random crops of the training runs, each turned by a random one of the eight symmetries."""

    def __init__(self, runs, stats, crop, residual, seed):
        self.runs = runs
        self.mean = torch.tensor(stats["mean"]).view(-1, 1, 1)
        self.std = torch.tensor(stats["std"]).view(-1, 1, 1)
        self.crop = crop
        self.residual = residual
        self.rng = random.Random(seed)
        # Square crops, no larger than the smallest run, so that a batch stacks.
        self.crop = min([crop] + [min(run["x"].shape[1:]) for run in runs])
        self.weights = [float(run["mask"].sum()) for run in runs]

    def sample(self):
        run = self.rng.choices(self.runs, weights=self.weights)[0]
        _, h, w = run["x"].shape
        c = self.crop
        i = self.rng.randint(0, h - c)
        j = self.rng.randint(0, w - c)
        window = (slice(None), slice(i, i + c), slice(j, j + c))
        x = (torch.from_numpy(run["x"][window]) - self.mean) / self.std
        y = torch.from_numpy(run["y"][window] - (run["kb"][window] if self.residual else 0))
        m = torch.from_numpy(run["mask"][i:i + c, j:j + c].astype(np.float32))
        return dihedral([x, y, m], self.rng.randrange(4), self.rng.random() < 0.5)

    def batch(self, size):
        samples = [self.sample() for _ in range(size)]
        return [torch.stack([s[n] for s in samples]) for n in range(3)]


# MARK: - Models

def groups(channels):
    return math.gcd(8, channels)


class Block(nn.Module):
    def __init__(self, a, b):
        super().__init__()
        self.body = nn.Sequential(nn.Conv2d(a, b, 3, padding=1), nn.GroupNorm(groups(b), b), nn.GELU(),
                                  nn.Conv2d(b, b, 3, padding=1), nn.GroupNorm(groups(b), b), nn.GELU())

    def forward(self, x):
        return self.body(x)


class UNet(nn.Module):
    """A 2-D U-Net: `depth` halvings, `width` channels at the top doubling at each."""

    def __init__(self, inputs, outputs=2, width=32, depth=4):
        super().__init__()
        widths = [width * 2 ** n for n in range(depth + 1)]
        self.down = nn.ModuleList([Block(inputs, widths[0])] +
                                  [Block(widths[n], widths[n + 1]) for n in range(depth)])
        self.up = nn.ModuleList([Block(widths[n + 1] + widths[n], widths[n]) for n in reversed(range(depth))])
        self.head = nn.Conv2d(widths[0], outputs, 1)
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


class SpectralConv(nn.Module):
    """The Fourier layer's global part: the lowest `modes` frequencies each way mixed across channels
    by learned complex weights, in float32 whatever the autocast."""

    def __init__(self, a, b, modes):
        super().__init__()
        self.modes = modes
        scale = 1 / (a * b)
        # Real and imaginary parts, for the positive and negative row frequencies.
        self.weights = nn.Parameter(scale * torch.randn(2, a, b, modes, modes, 2))

    def forward(self, x):
        with torch.autocast(device_type=x.device.type, enabled=False):
            x = x.float()
            h, w = x.shape[-2:]
            m1, m2 = min(self.modes, h // 2), min(self.modes, w // 2 + 1)
            spectrum = torch.fft.rfft2(x, norm="ortho")
            out = torch.zeros(x.shape[0], self.weights.shape[2], h, w // 2 + 1, dtype=spectrum.dtype,
                              device=x.device)
            weights = torch.view_as_complex(self.weights.float().contiguous())
            out[:, :, :m1, :m2] = torch.einsum("bixy,ioxy->boxy", spectrum[:, :, :m1, :m2],
                                               weights[0][:, :, :m1, :m2])
            out[:, :, -m1:, :m2] = torch.einsum("bixy,ioxy->boxy", spectrum[:, :, -m1:, :m2],
                                                weights[1][:, :, :m1, :m2])
            return torch.fft.irfft2(out, s=(h, w), norm="ortho")


class FNO(nn.Module):
    """A 2-D Fourier neural operator: lifted to `width` channels, `layers` Fourier layers (each a
    spectral convolution plus a pointwise one), projected to the outputs; padded so that the
    non-periodic map's edges do not wrap into each other."""

    def __init__(self, inputs, outputs=2, width=32, modes=24, layers=4, padding=16):
        super().__init__()
        self.lift = nn.Conv2d(inputs, width, 1)
        self.spectral = nn.ModuleList([SpectralConv(width, width, modes) for _ in range(layers)])
        self.pointwise = nn.ModuleList([nn.Conv2d(width, width, 1) for _ in range(layers)])
        self.project = nn.Sequential(nn.Conv2d(width, 4 * width, 1), nn.GELU(), nn.Conv2d(4 * width, outputs, 1))
        self.padding = padding
        self.multiple = 1

    def forward(self, x):
        h, w = x.shape[-2:]
        x = F.pad(self.lift(x), (0, self.padding, 0, self.padding))
        for n, (spectral, pointwise) in enumerate(zip(self.spectral, self.pointwise)):
            x = spectral(x) + pointwise(x)
            if n < len(self.spectral) - 1:
                x = F.gelu(x)
        return self.project(x[..., :h, :w])


def build(name, args, inputs=len(INPUTS)):
    if name == "unet":
        return UNet(inputs, width=args.width, depth=args.depth)
    if name == "fno":
        return FNO(inputs, width=args.width, modes=args.modes, layers=args.layers)
    raise ValueError("--model unet or fno, not %r" % name)


# MARK: - Devices and precision

def device_for(name):
    if name == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")
    return torch.device(name)


def precision(device, amp):
    """(autocast enabled, dtype, a GradScaler is needed)."""
    if amp == "off" or (amp == "auto" and device.type == "cpu"):
        return False, torch.float32, False
    if device.type == "cuda":
        if torch.cuda.is_bf16_supported():
            return True, torch.bfloat16, False
        return True, torch.float16, True
    if device.type == "mps":
        return True, torch.float16, False
    return True, torch.bfloat16, False


# MARK: - Judging

def judge(model, runs, stats, residual, device, autocast, dtype, multiple):
    """Median ratio and log-SD of predicted over run, peak and impulse, by scaled-distance band,
    over the runs' masks; and the same for Kingery–Bulmash alone; and the mean masked loss."""
    model.eval()
    mean = torch.tensor(stats["mean"]).view(1, -1, 1, 1)
    std = torch.tensor(stats["std"]).view(1, -1, 1, 1)
    errors, baseline, distances = [], [], []
    loss_sum, loss_count = 0.0, 0
    with torch.no_grad():
        for run in runs:
            x = (torch.from_numpy(run["x"])[None] - mean) / std
            h, w = x.shape[-2:]
            ph, pw = (-h) % multiple, (-w) % multiple
            x = F.pad(x, (0, pw, 0, ph), mode="replicate").to(device)
            with torch.autocast(device_type=device.type, dtype=dtype, enabled=autocast):
                out = model(x)
            out = out.float()[0, :, :h, :w].cpu().numpy()
            prediction = out + (run["kb"] if residual else 0)
            mask = run["mask"]
            error = (prediction - run["y"])[:, mask]
            loss_sum += float((error ** 2).sum())
            loss_count += error.size
            errors.append(error)
            baseline.append((run["kb"] - run["y"])[:, mask])
            distances.append(run["z"][mask])
    model.train()
    if not errors:
        return None
    error = np.concatenate(errors, axis=1)
    base = np.concatenate(baseline, axis=1)
    z = np.concatenate(distances)
    table = []
    for lo, hi in [(0, float("inf"))] + list(zip(BANDS, BANDS[1:])):
        inside = (z >= lo) & (z < hi)
        if inside.sum() == 0:
            continue
        row = {"band": "all" if lo == 0 and hi == float("inf") else "Z %g-%g" % (lo, hi), "cells": int(inside.sum())}
        for n, quantity in enumerate(("peak", "impulse")):
            e = error[n, inside]
            b = base[n, inside]
            row[quantity] = {"ratio": float(np.exp(np.median(e))), "logSD": float(e.std()),
                             "kbRatio": float(np.exp(np.median(b))), "kbLogSD": float(b.std())}
        table.append(row)
    return {"loss": loss_sum / max(loss_count, 1), "kbLoss": float((base ** 2).mean()), "bands": table}


def print_table(result, label):
    print("  %s: held-out loss %.4f (mean squared log error; Kingery-Bulmash alone %.4f)" % (
        label, result["loss"], result["kbLoss"]))
    print("    %-10s %9s  %-23s  %-23s" % ("band", "cells", "peak ratio / log-SD (KB)", "impulse ratio / log-SD (KB)"))
    for row in result["bands"]:
        p, i = row["peak"], row["impulse"]
        print("    %-10s %9d  %.2f / %.2f (%.2f / %.2f)  %.2f / %.2f (%.2f / %.2f)" % (
            row["band"], row["cells"], p["ratio"], p["logSD"], p["kbRatio"], p["kbLogSD"],
            i["ratio"], i["logSD"], i["kbRatio"], i["kbLogSD"]))
    sys.stdout.flush()


# MARK: - Training

def train(args):
    torch.manual_seed(args.seed)
    random.seed(args.seed)
    np.random.seed(args.seed)
    device = device_for(args.device)
    autocast, dtype, scaled = precision(device, args.amp)
    os.makedirs(args.out, exist_ok=True)
    runs = load_runs(args.data)
    if len(runs) < 2:
        raise SystemExit("train_field: %d usable runs in %s; at least 2 are needed" % (len(runs), args.data))
    checkpoint_path = os.path.join(args.out, "checkpoint.pt")
    resume = None
    if args.resume == "auto" and os.path.exists(checkpoint_path):
        resume = checkpoint_path
    elif args.resume not in ("auto", "none"):
        resume = os.path.expanduser(args.resume)
    state = torch.load(resume, map_location="cpu", weights_only=False) if resume else None
    if state:
        held = state["heldOut"]
        stats = state["stats"]
        print("train_field: resuming from %s at epoch %d" % (resume, state["epoch"]))
    else:
        held = split(runs, args.holdout, args.holdout_runs.split(",") if args.holdout_runs else None,
                     args.split_by, args.seed)
        stats = None
    training = [run for run in runs if run["id"] not in held]
    testing = [run for run in runs if run["id"] in held]
    if not training or not testing:
        raise SystemExit("train_field: the split leaves %d runs to train on and %d held out" % (
            len(training), len(testing)))
    stats = stats or statistics(training)
    with open(os.path.join(args.out, "split.json"), "w") as handle:
        json.dump({"training": [r["id"] for r in training], "heldOut": held, "by": args.split_by,
                   "seed": args.seed, "stats": stats, "inputs": INPUTS}, handle, indent=1)
    model = build(args.model, args).to(device)
    parameters = sum(p.numel() for p in model.parameters())
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=args.weight_decay)
    scaler = torch.amp.GradScaler(device.type, enabled=scaled)
    area = sum(run["x"].shape[1] * run["x"].shape[2] for run in training)
    crop = min([args.crop] + [min(run["x"].shape[1:]) for run in training])
    steps_per_epoch = args.steps_per_epoch or max(1, int(math.ceil(area / (crop ** 2) / args.batch)))
    total_steps = args.epochs * steps_per_epoch

    def rate(step):
        """A twentieth of the steps warming up, then a cosine down to a twentieth of `--lr`; by the
        step and this run's `--epochs`, so a resumed run asked for more epochs stretches the curve."""
        warm = max(1, total_steps // 20)
        if step < warm:
            return args.lr * (step + 1) / warm
        t = min(1.0, (step - warm) / max(1, total_steps - warm))
        return args.lr * (0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * t)))

    history, best, start_epoch = [], float("inf"), 0
    if state:
        model.load_state_dict(state["model"])
        optimizer.load_state_dict(state["optimizer"])
        if state.get("scaler"):
            scaler.load_state_dict(state["scaler"])
        history, best, start_epoch = state["history"], state["best"], state["epoch"]
        random.setstate(state["random"])
        torch.set_rng_state(state["torch"])
    crops = Crops(training, stats, args.crop, not args.no_residual, args.seed + start_epoch)
    print("train_field: %s, %d parameters, on %s (%s), %d runs to train on, %d held out (%s); %d steps of %d "
          "crops of %d a side an epoch" % (
              args.model, parameters, device, "autocast %s" % str(dtype).split(".")[-1] if autocast else "float32",
              len(training), len(testing), ", ".join(held), steps_per_epoch, args.batch, crop))
    sys.stdout.flush()
    if not state:
        reference = judge(model, testing, stats, not args.no_residual, device, autocast, dtype, model.multiple)
        print_table(reference, "before training")
    for epoch in range(start_epoch, args.epochs):
        began = time.time()
        total = 0.0
        for n in range(steps_per_epoch):
            for group in optimizer.param_groups:
                group["lr"] = rate(epoch * steps_per_epoch + n)
            x, y, m = (t.to(device, non_blocking=True) for t in crops.batch(args.batch))
            with torch.autocast(device_type=device.type, dtype=dtype, enabled=autocast):
                out = model(x)
            loss = (((out.float() - y) ** 2) * m[:, None]).sum() / (2 * m.sum().clamp(min=1))
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.unscale_(optimizer)
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            scaler.step(optimizer)
            scaler.update()
            total += float(loss.detach())
        seconds = time.time() - began
        result = judge(model, testing, stats, not args.no_residual, device, autocast, dtype, model.multiple)
        entry = {"epoch": epoch + 1, "trainLoss": total / steps_per_epoch, "heldOutLoss": result["loss"],
                 "seconds": seconds, "lr": optimizer.param_groups[0]["lr"], "bands": result["bands"]}
        history.append(entry)
        print("epoch %d/%d: train loss %.4f, held-out loss %.4f, %.1f s (%.0f ms a step)" % (
            epoch + 1, args.epochs, entry["trainLoss"], entry["heldOutLoss"], seconds, 1000 * seconds / steps_per_epoch))
        if (epoch + 1) % args.print_every == 0 or epoch + 1 == args.epochs:
            print_table(result, "epoch %d" % (epoch + 1))
        improved = result["loss"] < best
        best = min(best, result["loss"])
        checkpoint = {"model": model.state_dict(), "optimizer": optimizer.state_dict(), "scaler": scaler.state_dict() if scaled else None,
                      "epoch": epoch + 1, "best": best, "history": history, "args": vars(args), "stats": stats,
                      "heldOut": held, "inputs": INPUTS, "residual": not args.no_residual,
                      "random": random.getstate(), "torch": torch.get_rng_state()}
        torch.save(checkpoint, checkpoint_path + ".tmp")
        os.replace(checkpoint_path + ".tmp", checkpoint_path)
        if improved:
            torch.save({k: checkpoint[k] for k in ("model", "epoch", "args", "stats", "inputs", "residual")},
                       os.path.join(args.out, "best.pt"))
        with open(os.path.join(args.out, "metrics.json"), "w") as handle:
            json.dump({"model": args.model, "parameters": parameters, "device": str(device),
                       "precision": str(dtype) if autocast else "float32", "heldOut": held, "history": history},
                      handle, indent=1)
        sys.stdout.flush()
    return 0


# MARK: - Estimates

def footprint(model, grid, channels):
    """One forward pass at `grid` a side, batch 1, on the CPU under bfloat16 autocast (which keeps
    the same float32 layers as CUDA's float16): the bytes of what backward keeps (each layer's
    output, and the half-precision copy a convolution makes of a float32 input), and the
    floating-point operations of the convolutions and the spectral layers."""
    kept, flops, extra = [0], [0], [0]

    def hook(module, inputs, output):
        if not isinstance(output, torch.Tensor):
            return
        kept[0] += output.numel() * output.element_size()
        if isinstance(module, nn.Conv2d):
            k = module.kernel_size[0] * module.kernel_size[1]
            flops[0] += 2 * output.numel() * module.in_channels // module.groups * k
            if inputs and inputs[0].dtype == torch.float32:
                kept[0] += inputs[0].numel() * 2
        if isinstance(module, SpectralConv):
            a, b = module.weights.shape[1], module.weights.shape[2]
            h, w = output.shape[-2:]
            m1, m2 = min(module.modes, h // 2), min(module.modes, w // 2 + 1)
            # Two blocks of complex products (8 real operations each), and the two transforms.
            flops[0] += 2 * 8 * a * b * m1 * m2 + 5 * (a + b) * h * w * math.log2(max(h * w, 2))
            # The transforms' float32 and complex arrays, read and written, which backward repeats.
            extra[0] += 20 * (a + b) * h * w

    handles = [m.register_forward_hook(hook) for m in model.modules()
               if len(list(m.children())) == 0 or isinstance(m, SpectralConv)]
    with torch.no_grad(), torch.autocast(device_type="cpu", dtype=torch.bfloat16):
        model(torch.zeros(1, channels, grid, grid))
    for handle in handles:
        handle.remove()
    return kept[0], flops[0], extra[0]


def estimate(args):
    device = device_for(args.device)
    autocast, dtype, scaled = precision(device, args.amp)
    grids = [int(g) for g in str(args.grid).split(",")]
    models = args.model.split(",") if "," in args.model else (["unet", "fno"] if args.model == "both" else [args.model])
    gpus = [GPUS[g] for g in args.gpu.split(",")]
    print("Estimates per training step, batch %d, mixed precision on the PCs (activations as autocast keeps them, "
          "weights, gradients and Adam float32), at %.0f%% of peak arithmetic and %.0f%% of peak bandwidth, plus %.1f GB "
          "for CUDA's context and workspace." % (args.batch, 100 * EFFICIENCY["compute"],
                                                  100 * EFFICIENCY["bandwidth"], EFFICIENCY["overheadGB"]))
    results = []
    for name in models:
        for grid in grids:
            model = build(name, args)
            parameters = sum(p.numel() for p in model.parameters())
            kept, flops, spectral = footprint(model, grid, len(INPUTS))
            # What backward keeps, and a tenth more for the functional steps the hooks do not see
            # (pooling, upsampling, concatenation).
            activation_bytes = 1.1 * kept * args.batch
            # float32 weights, gradients and Adam's two moments.
            state_bytes = parameters * 16
            train_flops = 3 * flops * args.batch
            # Each activation written once forward, read and written about twice more backward.
            traffic = 4 * activation_bytes + 3 * state_bytes + 3 * spectral * args.batch
            row = {"model": name, "grid": grid, "batch": args.batch, "parameters": parameters,
                   "activationsGB": activation_bytes / 1e9, "stateGB": state_bytes / 1e9,
                   "trainGFlop": train_flops / 1e9, "gpus": {}}
            for gpu in gpus:
                memory = (activation_bytes + state_bytes) / 1e9 + EFFICIENCY["overheadGB"]
                seconds = max(train_flops / (EFFICIENCY["compute"] * gpu["tflops"] * 1e12),
                              traffic / (EFFICIENCY["bandwidth"] * gpu["bandwidthGBs"] * 1e9))
                per_sample = (activation_bytes / args.batch) / 1e9
                fits = int((gpu["memGB"] - EFFICIENCY["overheadGB"] - state_bytes / 1e9) // per_sample)
                row["gpus"][gpu["name"]] = {"memoryGB": memory, "seconds": seconds, "largestBatch": fits}
            # Measured here.
            if not args.no_measure:
                row["measured"] = measure(model, grid, args.batch, device, autocast, dtype, scaled)
            results.append(row)
            print("%s at %d², batch %d: %.2f M parameters, %.1f GFLOP a step; activations %.2f GB, weights and "
                  "optimiser %.2f GB" % (name, grid, args.batch, parameters / 1e6, train_flops / 1e9,
                                        row["activationsGB"], row["stateGB"]))
            for gpu_name, g in row["gpus"].items():
                print("  %s: about %.1f GB of %d GB, %.0f ms a step (%.1f samples/s); batch up to %d fits" % (
                    gpu_name, g["memoryGB"], 12, 1000 * g["seconds"], args.batch / g["seconds"], g["largestBatch"]))
            if row.get("measured"):
                m = row["measured"]
                print("  measured here on %s (%s): %.0f ms a step%s" % (
                    m["device"], m["precision"], 1000 * m["seconds"],
                    ", %.2f GB allocated at the peak" % m["peakGB"] if m.get("peakGB") else ""))
            sys.stdout.flush()
    if args.out:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "estimate.json"), "w") as handle:
            json.dump({"efficiency": EFFICIENCY, "gpus": GPUS, "rows": results}, handle, indent=1)
    return 0


def measure(model, grid, batch, device, autocast, dtype, scaled, steps=3):
    """A few training steps on random data on this machine's device: seconds a step and, on CUDA,
    the peak allocated."""
    model = model.to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-4)
    scaler = torch.amp.GradScaler(device.type, enabled=scaled)
    x = torch.randn(batch, len(INPUTS), grid, grid, device=device)
    y = torch.randn(batch, 2, grid, grid, device=device)

    def sync():
        if device.type == "cuda":
            torch.cuda.synchronize()
        elif device.type == "mps":
            torch.mps.synchronize()

    if device.type == "cuda":
        torch.cuda.reset_peak_memory_stats()
    elif device.type == "mps":
        torch.mps.empty_cache()
        before = torch.mps.driver_allocated_memory()
    try:
        times = []
        for n in range(steps + 1):
            sync()
            began = time.time()
            with torch.autocast(device_type=device.type, dtype=dtype, enabled=autocast):
                out = model(x)
            loss = ((out.float() - y) ** 2).mean()
            optimizer.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(optimizer)
            scaler.update()
            sync()
            if n:
                times.append(time.time() - began)
    except RuntimeError as error:
        return {"device": str(device), "precision": str(dtype) if autocast else "float32",
                "seconds": float("nan"), "error": str(error).split("\n")[0]}
    result = {"device": str(device), "precision": str(dtype).split(".")[-1] if autocast else "float32",
              "seconds": sorted(times)[len(times) // 2]}
    if device.type == "cuda":
        result["peakGB"] = torch.cuda.max_memory_allocated() / 1e9
    elif device.type == "mps":
        # The driver's allocation after the steps, cache included: an upper bound.
        result["peakGB"] = (torch.mps.driver_allocated_memory() - before) / 1e9
    del optimizer, x, y
    model.to("cpu")
    if device.type == "mps":
        torch.mps.empty_cache()
    return result


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--data")
    parser.add_argument("--out")
    parser.add_argument("--model", default="unet", help="unet or fno (for --estimate also both, or a list)")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--crop", type=int, default=256)
    parser.add_argument("--steps-per-epoch", type=int, default=0, help="0: about the training runs' area once")
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--depth", type=int, default=4)
    parser.add_argument("--modes", type=int, default=24)
    parser.add_argument("--layers", type=int, default=4)
    parser.add_argument("--holdout", type=float, default=0.2)
    parser.add_argument("--holdout-runs", default="")
    parser.add_argument("--split-by", choices=("run", "layout"), default="run")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--amp", choices=("auto", "on", "off"), default="auto")
    parser.add_argument("--resume", default="auto", help="auto (OUT/checkpoint.pt if there), a path, or none")
    parser.add_argument("--no-residual", action="store_true")
    parser.add_argument("--print-every", type=int, default=5)
    parser.add_argument("--estimate", action="store_true")
    parser.add_argument("--grid", default="256,512")
    parser.add_argument("--gpu", default="rtx3080ti,rtx4080laptop")
    parser.add_argument("--no-measure", action="store_true")
    args = parser.parse_args(argv)
    if args.estimate:
        return estimate(args)
    if not args.data or not args.out:
        parser.error("--data and --out are needed to train (or --estimate)")
    return train(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
