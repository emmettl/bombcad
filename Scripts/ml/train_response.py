#!/usr/bin/env python3
"""The live drag's learned response (emmettl/bombcad-work#112; docs/learned-models.md, "The live
drag's learned response"): three small networks trained on `scenebench response-data`'s rows, the
CPU code they stand in for giving the answers.

- component: a component's load and construction -> its damage level (none, moderate, heavy,
  hazardous, failed) and whether its glass breaks, at the charge's yield;
- side: a glazed side's strips' loads, its mix and the draws' spreads -> its glass chances (some
  broken, blown out, the share broken, thrown past 3b, its openings blown out);
- building: a building's walls' and roof's loads and construction -> its chances of walls moderate
  or worse, heavy or worse, and roof moderate or worse.

Each is dense layers with SiLU between, its inputs standardised. Frames whose index is 9 modulo 10
are held out. Run as remote-train.py runs a script: `--data <folder> --out <folder>`; the weights go
to `<out>/live-response.bclr` (`LiveResponse.Weights`), with `report.json`.

    for f in data/*.f32 data/*.i32; do gzip -1 -c $f > packed/$(basename $f).gz; done; cp data/meta.json packed/
    python3 -I Scripts/ml/remote-train.py bombcad-pc packed Scripts/ml/train_response.py --job live-response-1
"""

import argparse
import gzip
import json
import math
import struct
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn

LEVELS = 5
SHAPE_WIDTH = 18  # `LiveResponse.shapeWidth`


def array(folder: Path, name: str, dtype):
    """A data file, or its gzip (`gzip -1` before sending: the rows' zeros pack 20 to 40 times)."""
    if (folder / name).exists():
        return np.fromfile(folder / name, dtype=dtype)
    with gzip.open(folder / (name + ".gz"), "rb") as f:
        return np.frombuffer(f.read(), dtype=dtype)


def load(folder: Path, unit: str, width: int, outputs: int):
    x = array(folder, f"{unit}-x.f32", np.float32).reshape(-1, width)
    y = array(folder, f"{unit}-y.f32", np.float32).reshape(-1, outputs)
    w = array(folder, f"{unit}-w.f32", np.float32)
    frame = array(folder, f"{unit}-frame.i32", np.int32)
    n = min(len(x), len(y), len(w), len(frame))
    return x[:n], y[:n], w[:n], frame[:n]


def quantised(x):
    """The component rows' damage load as the SDOF meets it (`LiveResponse.quantized`): the log peak
    and log impulse rounded to steps of 3%, the rise to a twentieth (rows made before the inputs were
    rounded are rounded here; rounding again changes nothing)."""
    x = np.array(x, dtype=np.float32)
    step = math.log10(1.03)
    x[:, 0] = np.round(x[:, 0].astype(np.float64) / step) * step
    x[:, 1] = np.round(x[:, 1].astype(np.float64) / step) * step
    x[:, 2] = np.round(x[:, 2].astype(np.float64) * 20) / 20
    return x


class Dense(nn.Module):
    def __init__(self, sizes):
        super().__init__()
        self.layers = nn.ModuleList(nn.Linear(a, b) for a, b in zip(sizes[:-1], sizes[1:]))

    def forward(self, x):
        for n, layer in enumerate(self.layers):
            x = layer(x)
            if n < len(self.layers) - 1:
                x = nn.functional.silu(x)
        return x


def standardisation(x):
    mean = x.mean(0).astype(np.float64)
    std = x.std(0).astype(np.float64)
    std[std < 1e-6] = 1.0
    return mean, std


def losses(unit, out, y, w):
    if unit == "component":
        level = y[:, 0].long().clamp(0, LEVELS - 1)
        ce = nn.functional.cross_entropy(out[:, :LEVELS], level, reduction="none")
        bce = nn.functional.binary_cross_entropy_with_logits(out[:, LEVELS], y[:, 1], reduction="none")
        return ((ce + bce) * w).sum() / w.sum()
    bce = nn.functional.binary_cross_entropy_with_logits(out, y, reduction="none").mean(1)
    return (bce * w).sum() / w.sum()


def judge(unit, out, y, w):
    """Weighted measures on held-out rows."""
    w = w / w.sum()
    if unit == "component":
        level = out[:, :LEVELS].argmax(1)
        broken = (out[:, LEVELS] > 0).float()
        exact = (level == y[:, 0].long()).float()
        damaged = y[:, 0] > 0
        return {
            "levelExact": float((exact * w).sum()),
            "levelExactWhereDamaged": float(exact[damaged].mean()) if damaged.any() else None,
            "damagedRows": int(damaged.sum()),
            "brokenExact": float(((broken == y[:, 1]).float() * w).sum()),
        }
    p = torch.sigmoid(out)
    error = (p - y).abs()
    result = {}
    for k in range(y.shape[1]):
        result[f"within01_{k}"] = float(((error[:, k] <= 0.1).float() * w).sum())
        result[f"mae_{k}"] = float((error[:, k] * w).sum())
        result[f"bias_{k}"] = float(((p[:, k] - y[:, k]) * w).sum())
    return result


def train(unit, x, y, w, frame, sizes, epochs, batch, lr, device, log):
    held = frame % 10 == 9
    mean, std = standardisation(x[~held])
    xs = ((x - mean) / std).astype(np.float32)
    tx = torch.from_numpy(xs[~held]).to(device)
    ty = torch.from_numpy(y[~held]).to(device)
    tw = torch.from_numpy(w[~held]).to(device)
    vx = torch.from_numpy(xs[held]).to(device)
    vy = torch.from_numpy(y[held]).to(device)
    vw = torch.from_numpy(w[held]).to(device)
    model = Dense(sizes).to(device)
    optimiser = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-5)
    steps = epochs * math.ceil(len(tx) / batch)
    schedule = torch.optim.lr_scheduler.OneCycleLR(optimiser, max_lr=lr, total_steps=steps, pct_start=0.1)
    best = (math.inf, None, None)
    for epoch in range(epochs):
        model.train()
        order = torch.randperm(len(tx), device=device)
        total = 0.0
        for start in range(0, len(tx), batch):
            idx = order[start:start + batch]
            loss = losses(unit, model(tx[idx]), ty[idx], tw[idx])
            optimiser.zero_grad()
            loss.backward()
            optimiser.step()
            schedule.step()
            total += float(loss) * len(idx)
        model.eval()
        with torch.no_grad():
            out = torch.cat([model(vx[s:s + 65536]) for s in range(0, len(vx), 65536)])
            held_loss = float(losses(unit, out, vy, vw))
            measures = judge(unit, out, vy, vw)
        log(f"{unit} epoch {epoch}: train {total / len(tx):.5f}, held out {held_loss:.5f}, {json.dumps(measures)}")
        if held_loss < best[0]:
            best = (held_loss, {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}, measures)
    model.load_state_dict(best[1])
    return model, mean, std, best[0], best[2], int((~held).sum()), int(held.sum())


def export(path: Path, meta, nets, dtype="float16"):
    """`LiveResponse.Weights`: "BCLR", version 2, the header's length, the JSON header, then the
    tensors in `dtype` (float16 by default, as the field model's; or float32): each layer's weights,
    out × in, then its biases. Each network's means and deviations are in the header."""
    blobs = []
    offset = 0
    header = {"format": "bclr", "version": 2, "dtype": dtype,
              "constructionWidth": meta["componentWidth"] - 3 - SHAPE_WIDTH,
              "glazingWidth": meta["sideWidth"] - 9 * 4 - 5,
              "slopeStep": 0.25, "sideStrips": 4, "buildingWalls": 8, "networks": {}}
    for name, (model, mean, std, outputs) in nets.items():
        layers = []
        for layer in model.layers:
            weight = layer.weight.detach().cpu().numpy().astype(np.float32)
            bias = layer.bias.detach().cpu().numpy().astype(np.float32)
            layers.append({"inputs": int(weight.shape[1]), "outputs": int(weight.shape[0]), "offset": offset})
            blobs += [weight.ravel().astype(dtype), bias.ravel().astype(dtype)]
            offset += weight.size + bias.size
        header["networks"][name] = {"inputs": int(model.layers[0].in_features), "mean": mean.tolist(),
                                    "std": std.tolist(), "layers": layers, "outputs": outputs}
    header.update(meta.get("trained", {}))
    text = json.dumps(header).encode()
    with open(path, "wb") as f:
        f.write(b"BCLR")
        f.write(struct.pack("<II", 2, len(text)))
        f.write(text)
        for blob in blobs:
            f.write(blob.tobytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch", type=int, default=4096)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--hidden", default="component:64,64,64;side:128,128,64;building:128,128,64")
    parser.add_argument("--units", default="component,side,building")
    parser.add_argument("--dtype", default="float16", choices=["float16", "float32"])
    parser.add_argument("--keep", help="an earlier round's nets.pt, whose networks not trained now are kept")
    args = parser.parse_args()
    data = Path(args.data)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    log_file = open(out / "train.log", "a")

    def log(text):
        print(text, flush=True)
        log_file.write(text + "\n")
        log_file.flush()

    # One district's data, or a folder of districts', each its own folder with its meta.json.
    folders = [data] if (data / "meta.json").exists() else sorted(p for p in data.iterdir() if (p / "meta.json").exists())
    metas = [json.loads((f / "meta.json").read_text()) for f in folders]
    meta = metas[0]
    for other in metas[1:]:
        for key in ("componentWidth", "sideWidth", "buildingWidth"):
            assert other[key] == meta[key], f"{key} differs between districts"
    hidden = {k: [int(v) for v in s.split(",")] for k, s in (p.split(":") for p in args.hidden.split(";"))}
    widths = {"component": meta["componentWidth"], "side": meta["sideWidth"], "building": meta["buildingWidth"]}
    outputs = {"component": LEVELS + 1, "side": len(meta["sideOutputs"]), "building": len(meta["buildingOutputs"])}
    names = {"component": ["none", "moderate", "heavy", "hazardous", "failed", "glassBroken"],
             "side": meta["sideOutputs"], "building": meta["buildingOutputs"]}
    answers = {"component": 2, "side": len(meta["sideOutputs"]), "building": len(meta["buildingOutputs"])}
    torch.manual_seed(1)
    nets = {}
    report = {"device": device, "units": {}}
    for unit in args.units.split(","):
        started = time.time()
        parts = [load(f, unit, widths[unit], answers[unit]) for f in folders]
        x = np.concatenate([p[0] for p in parts])
        y = np.concatenate([p[1] for p in parts])
        w = np.concatenate([p[2] for p in parts])
        # Each district's frames numbered apart; frames 9 modulo 10 of each held out.
        frame = np.concatenate([p[3].astype(np.int64) + 100000 * n for n, p in enumerate(parts)])
        if unit == "component":
            x = quantised(x)
        log(f"{unit}: {len(x)} rows of {widths[unit]} inputs, {len(np.unique(frame))} frames")
        sizes = [widths[unit], *hidden[unit], outputs[unit]]
        model, mean, std, held, measures, trained, heldRows = train(
            unit, x, y, w, frame, sizes, args.epochs, args.batch, args.lr, device, log)
        nets[unit] = (model, mean, std, names[unit])
        report["units"][unit] = {"sizes": sizes, "heldOutLoss": held, "heldOut": measures, "rows": trained,
                                 "heldOutRows": heldRows, "seconds": time.time() - started}
    if args.keep:
        kept = torch.load(args.keep, weights_only=False)
        for unit, (state, sizes, mean, std, names_) in kept.items():
            if unit in nets:
                continue
            model = Dense(sizes)
            model.load_state_dict(state)
            nets[unit] = (model, mean, std, names_)
            report["units"][unit] = {"kept": args.keep}
    districts = ", ".join(f"{m['district']} ({len(m['frames'])} frames)" for m in metas)
    meta["trained"] = {"trainedOn": f"{data.name}: {districts}",
                       "epochs": args.epochs, "heldOut": "frames 9 modulo 10"}
    torch.save({k: (m.state_dict(), [l.in_features for l in m.layers] + [m.layers[-1].out_features], mean, std, o)
                for k, (m, mean, std, o) in nets.items()}, out / "nets.pt")
    export(out / "live-response.bclr", meta, nets, args.dtype)
    if args.dtype != "float32":
        export(out / "live-response-float32.bclr", meta, nets, "float32")
    (out / "report.json").write_text(json.dumps(report, indent=1))
    log(json.dumps(report))


if __name__ == "__main__":
    main()
