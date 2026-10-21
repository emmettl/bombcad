#!/usr/bin/env python3
"""Export a trained field U-Net (train_field.py's best.pt) for the app's quick estimate.

    python export_field_weights.py --model OUT/best.pt --out field-unet.bcfw [--dtype float16]
        [--data DATASET --reference RUN,RUN --reference-out FOLDER]

The app runs the network itself (BlastCore's `LearnedFieldNetwork`, on MPSGraph), so it needs the
weights in a form Swift reads without PyTorch: one file, `.bcfw`, little-endian throughout:

- the 4 bytes `BCFW`, a uint32 version (1) and a uint32 header length;
- the header, UTF-8 JSON, padded with spaces to a multiple of 16 bytes: the architecture (`model`,
  `width`, `depth`, `inputs`), the input channels' standardisation (`stats`), whether the network
  predicts corrections to Kingery–Bulmash's logs (`residual`), its outputs, its training target
  (`impulse`), the held-out runs, the source checkpoint's SHA-256 and epoch, and `tensors`: each
  state-dict entry's name, shape, and offset and count of values in the payload;
- the payload, every tensor's values in C order as `dtype` (float16 by default, about 16 MB for
  the 7.9 M-parameter U-Net; float32 doubles it).

With `--reference`, it also writes, for each named run of `--data`, the PyTorch prediction the
Swift network is checked against (BlastCoreTests' `LearnedFieldNetworkTests`): the run's
`inputs.npy` copied, and `<id>.logpeak.npy`, the network's natural log of peak overpressure (Pa)
over the run's whole plan, Kingery–Bulmash's log added, computed on the CPU in float32 with the
weights as exported (so rounded to float16 when they are). `reference.json` records the runs and,
for each, how far the prediction with the checkpoint's own float32 weights lies from it.

The weights are not committed (the repository is public, and they are 16 MB): they live on
StudioData beside the checkpoint, and the app reads them from a path (docs/learned-models.md).
"""
import argparse
import hashlib
import json
import os
import shutil
import struct
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import train_field  # noqa: E402

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
    if args.model != "unet":
        raise SystemExit("export_field_weights: only the U-Net is exported (%s is %s)" % (path, args.model))
    model = train_field.build("unet", args)
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
        "inputs": state.get("inputs", train_field.INPUTS), "stats": state["stats"],
        "residual": bool(state.get("residual", True)), "outputs": ["logPeakOverpressure", "logImpulse"],
        "impulse": getattr(args, "impulse", "all"), "multiple": 2 ** args.depth,
        "groupNormGroups": 8, "groupNormEpsilon": 1e-5,
        "dtype": "float16" if dtype == np.float16 else "float32",
        "source": os.path.abspath(source), "sourceSHA256": sha256(source), "epoch": state.get("epoch"),
        "holdout": getattr(args, "holdout_layouts", "") or getattr(args, "holdout_runs", ""),
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


def predict_log_peak(model, stats, run):
    """The network's log peak over the run's plan (as judge_field.predict, peak channel only)."""
    mean = torch.tensor(stats["mean"]).view(1, -1, 1, 1)
    std = torch.tensor(stats["std"]).view(1, -1, 1, 1)
    x = (torch.from_numpy(run["x"])[None] - mean) / std
    h, w = x.shape[-2:]
    multiple = model.multiple
    x = torch.nn.functional.pad(x, (0, (-w) % multiple, 0, (-h) % multiple), mode="replicate")
    with torch.no_grad():
        out = model(x).float()[0, 0, :h, :w].numpy()
    return (out + run["kb"][0]).astype(np.float32)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--model", required=True, help="train_field.py's best.pt")
    parser.add_argument("--out", required=True, help="the .bcfw file to write")
    parser.add_argument("--dtype", choices=("float16", "float32"), default="float16")
    parser.add_argument("--data", help="the dataset, for --reference")
    parser.add_argument("--reference", default="", help="runs to write PyTorch's predictions for")
    parser.add_argument("--reference-out", help="folder for the references")
    parser.add_argument("--threads", type=int, default=0)
    args = parser.parse_args(argv)
    if args.threads:
        torch.set_num_threads(args.threads)
    dtype = np.float16 if args.dtype == "float16" else np.float32
    model, state, margs = load(args.model)
    header = write(args.out, model, state, margs, args.model, dtype)
    size = os.path.getsize(args.out)
    print("export_field_weights: %s, %d tensors, %d values, %.1f MB (%s)" % (
        args.out, len(header["tensors"]), sum(t["count"] for t in header["tensors"]), size / 1e6, header["dtype"]))
    if not args.reference:
        return 0
    if not args.data or not args.reference_out:
        parser.error("--reference needs --data and --reference-out")
    os.makedirs(args.reference_out, exist_ok=True)
    # The network as exported: its weights rounded to the file's type.
    rounded = train_field.build("unet", margs)
    rounded.load_state_dict({k: torch.from_numpy(v.detach().numpy().astype(dtype).astype(np.float32))
                             for k, v in model.state_dict().items()})
    rounded.eval()
    record = {"weights": os.path.abspath(args.out), "weightsSHA256": sha256(args.out), "dtype": header["dtype"],
              "runs": []}
    for run_id in args.reference.split(","):
        run = train_field.load_run(os.path.join(args.data, "runs", run_id), margs.impulse)
        if run is None:
            raise SystemExit("export_field_weights: %s is not a finished run of %s" % (run_id, args.data))
        exported = predict_log_peak(rounded, state["stats"], run)
        original = predict_log_peak(model, state["stats"], run)
        np.save(os.path.join(args.reference_out, run_id + ".logpeak.npy"), exported)
        shutil.copyfile(os.path.join(args.data, "runs", run_id, "inputs.npy"),
                        os.path.join(args.reference_out, run_id + ".inputs.npy"))
        difference = np.abs(exported - original)
        entry = {"id": run_id, "rows": int(exported.shape[0]), "columns": int(exported.shape[1]),
                 "roundingMaxAbsLog": float(difference.max()), "roundingMeanAbsLog": float(difference.mean())}
        record["runs"].append(entry)
        print("  %s: %d x %d; the file's %s weights against the checkpoint's float32: log peak within %.2e (mean %.2e)"
              % (run_id, entry["rows"], entry["columns"], header["dtype"], entry["roundingMaxAbsLog"],
                 entry["roundingMeanAbsLog"]))
        sys.stdout.flush()
    with open(os.path.join(args.reference_out, "reference.json"), "w") as handle:
        json.dump(record, handle, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
