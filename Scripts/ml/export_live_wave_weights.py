#!/usr/bin/env python3
"""Export the live wave's learned refinement (train_live_wave.py's best.pt) for the app.

    python export_live_wave_weights.py --model OUT/best.pt --out live-wave-unet.bcfw [--dtype float16]
        [--reference PAIR_FOLDER,… --reference-out FOLDER]

The same `.bcfw` file as export_field_weights.py writes (its docstring gives the layout), with the
refinement's nine inputs and three outputs (`outputs`) and no group norms (`groupNormGroups` 0),
which BlastModel's `LearnedField.Weights` reads as `LiveWave.Refinement`'s and BlastCore's
`LearnedFieldNetwork` runs (emmettl/bombcad-work#115; docs/live-wave.md).

With `--reference`, for each `blastmodel live-wave-features` pair folder (runs/<id>/c<k>), the
network's three corrections over its whole plan, on the CPU in float32 with the weights as
exported, as `<id>-c<k>.corrections.npy` (3 x rows x columns), for checking `scenebench
live-wave-predict` against; `reference.json` records how far the checkpoint's own float32 weights
lie from them.
"""
import argparse
import hashlib
import json
import os
import struct
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import train_live_wave  # noqa: E402

MAGIC = b"BCFW"
VERSION = 1


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load(path):
    state = torch.load(path, map_location="cpu", weights_only=False)
    args = argparse.Namespace(**state["args"])
    UNet = train_live_wave.build_modules()
    model = UNet(len(state["inputs"]), len(state["outputs"]), args.width, args.depth)
    model.load_state_dict(state["model"])
    model.eval()
    return model, state, args


def write(path, model, state, args, source, dtype):
    tensors, chunks, offset = [], [], 0
    for name, value in model.state_dict().items():
        array = value.detach().cpu().numpy().astype(dtype)
        tensors.append({"name": name, "shape": list(array.shape), "offset": offset, "count": int(array.size)})
        chunks.append(array.astype(array.dtype.newbyteorder("<")).tobytes())
        offset += int(array.size)
    header = {
        "format": "bombcad-field-weights-1", "model": "unet", "width": args.width, "depth": args.depth,
        "inputs": state["inputs"], "stats": state["stats"], "residual": True, "outputs": state["outputs"],
        "multiple": 2 ** args.depth, "groupNormGroups": 0, "groupNormEpsilon": 1e-5,
        "dtype": "float16" if dtype == np.float16 else "float32",
        "source": "/".join(os.path.abspath(source).split(os.sep)[-3:]), "sourceSHA256": sha256(source),
        "epoch": state.get("epoch"), "holdout": "beirut (never trained on); validation " + args.validate_layouts,
        "tensors": tensors,
    }
    text = json.dumps(header, indent=1).encode("utf-8")
    text += b" " * ((-len(text)) % 16)
    with open(path + ".tmp", "wb") as handle:
        handle.write(MAGIC + struct.pack("<II", VERSION, len(text)))
        handle.write(text)
        for chunk in chunks:
            handle.write(chunk)
    os.replace(path + ".tmp", path)
    return header


def corrections(model, stats, features):
    mean = torch.tensor(stats["mean"], dtype=torch.float32).view(1, -1, 1, 1)
    std = torch.tensor(stats["std"], dtype=torch.float32).view(1, -1, 1, 1)
    x = (torch.from_numpy(features.astype(np.float32))[None] - mean) / std
    h, w = x.shape[-2:]
    multiple = model.multiple
    x = torch.nn.functional.pad(x, (0, (-w) % multiple, 0, (-h) % multiple), mode="replicate")
    with torch.no_grad():
        return model(x).float()[0, :, :h, :w].numpy().astype(np.float32)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    parser.add_argument("--reference", default="")
    parser.add_argument("--reference-out")
    args = parser.parse_args(argv)
    dtype = np.float16 if args.dtype == "float16" else np.float32
    model, state, margs = load(args.model)
    header = write(args.out, model, state, margs, args.model, dtype)
    print("export_live_wave_weights: %s, %d tensors, %d values, %.1f MB (%s), epoch %s" % (
        args.out, len(header["tensors"]), sum(t["count"] for t in header["tensors"]),
        os.path.getsize(args.out) / 1e6, header["dtype"], header["epoch"]))
    if not args.reference:
        return 0
    if not args.reference_out:
        parser.error("--reference needs --reference-out")
    os.makedirs(args.reference_out, exist_ok=True)
    UNet = train_live_wave.build_modules()
    rounded = UNet(len(state["inputs"]), len(state["outputs"]), margs.width, margs.depth)
    rounded.load_state_dict({k: torch.from_numpy(v.detach().numpy().astype(dtype).astype(np.float32))
                             for k, v in model.state_dict().items()})
    rounded.eval()
    record = {"weightsSHA256": sha256(args.out), "dtype": header["dtype"], "pairs": []}
    for folder in args.reference.split(","):
        features = np.load(os.path.join(folder, "features.npy"))
        name = "%s-%s" % (os.path.basename(os.path.dirname(os.path.normpath(folder))), os.path.basename(os.path.normpath(folder)))
        exported = corrections(rounded, state["stats"], features)
        original = corrections(model, state["stats"], features)
        np.save(os.path.join(args.reference_out, name + ".corrections.npy"), exported)
        difference = np.abs(exported - original)
        record["pairs"].append({"pair": name, "folder": os.path.abspath(folder), "shape": list(exported.shape),
                                "roundingMaxAbs": float(difference.max()), "roundingMeanAbs": float(difference.mean())})
        print("  %s: %s; the file's weights against the checkpoint's float32 within %.2e (mean %.2e)" % (
            name, exported.shape, difference.max(), difference.mean()), flush=True)
    with open(os.path.join(args.reference_out, "reference.json"), "w") as handle:
        json.dump(record, handle, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
