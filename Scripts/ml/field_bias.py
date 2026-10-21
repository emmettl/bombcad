#!/usr/bin/env python3
"""The learned field model's training runs on finer air: how far 4 m cells bias the fields.

    python3 -I Scripts/ml/field_bias.py run --only id,id --dx 4,2 --out /Volumes/StudioData/bombcad/ml/bias
        [--radius 512] [--tag r512] [--levels 6,10,14,20] [--dry-run]
    python -I Scripts/ml/field_bias.py analyse --out /Volumes/StudioData/bombcad/ml/bias [--coarse 4 --fine 2]
        [--tag ''] [--json summary.json]

`run` exports each run of the list (field-runs.json's main set) again with `scenebench field-export
--first-phase` at each cell size of `--dx`, with the fields at more heights and over the roofs
(`--levels`, `--roof`), under gpu-slot, into OUT/<id>[-tag]/dx<dx>/. `--radius` makes the domain
smaller (the same district and charge, the same top by the open-face rule).

`analyse` compares each run's coarse export against its fine one (emmettl/bombcad-work#69):

- **cells**: each coarse plan cell against the mean of the fine cells it holds, where all of them are
  in the fine mask, at every level; by scaled distance, by whether the line from the charge crosses
  a building, and by whether the cell is beside one;
- **façades**: each façade strip (the run's `field-surrogate` strips, judge_field.py's cache) at the
  level its storey spans, the mean of the cells in front of it at each size (judge_field.py's
  `front_cells`; on the fine cells, the first in the mask going out from the face);
- **Kingery–Bulmash**: the open, in-sight cells' ratio to the incident values, at each size.

Each is the median of fine over coarse and the standard deviation of its logarithm, for the peak and
the first phase's impulse.
"""
import argparse
import csv
import importlib.util
import json
import math
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
GPU_SLOT = os.path.expanduser("~/.local/bin/gpu-slot")
STRIPS = "/Volumes/StudioData/bombcad/ml/judge/strips"
BANDS = [0, 3, 5, 7, 10, 14, 20, 28, 40]


def field_runs():
    spec = importlib.util.spec_from_file_location("field_runs", os.path.join(HERE, "field-runs.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(args):
    fr = field_runs()
    with open(fr.LIST) as handle:
        plan = json.load(handle)
    wanted = args.only.split(",")
    runs = [r for r in plan["sets"]["main"] if r["id"] in wanted]
    scenebench = os.path.abspath(args.scenebench)
    failures = 0
    for r in runs:
        layout = plan["layouts"][r["layout"]]
        for dx in [float(d) for d in args.dx.split(",")]:
            name = r["id"] + ("-" + args.tag if args.tag else "")
            out = os.path.join(args.out, name, "dx%g" % dx)
            if fr.done(out):
                print("%s at %g m: done" % (name, dx), flush=True)
                continue
            case = dict(r, radiusM=args.radius or r["radiusM"])
            arguments = fr.field_arguments(case, layout, fr.inputs_for(r["layout"], layout, make=False), out)
            arguments[arguments.index("--dx") + 1] = "%g" % dx
            arguments += ["--first-phase", "--roof"] + (["--levels", args.levels] if args.levels else [])
            # The solver's memory, by the cells at this size (73 bytes each), with room to spare.
            estimate = fr.estimate(case, plan["layouts"])
            cells = estimate["cells"] * (4 / dx) ** 3
            memory = max(4, int(math.ceil(cells * 73 * 1.3 / 1e9 + (2 if layout["kind"] == "beirut" else 1))))
            command = [GPU_SLOT, "--mem", str(memory), scenebench] + arguments
            print("%s at %g m: %s" % (name, dx, " ".join(command)), flush=True)
            if args.dry_run:
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out + ".log", "w") as log:
                try:
                    code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                          timeout=5400).returncode
                except subprocess.TimeoutExpired:
                    code = 124
            print("  exit %d" % code, flush=True)
            failures += code != 0
    return 1 if failures else 0


# MARK: - Analysis

def load(folder):
    import numpy as np
    with open(os.path.join(folder, "meta.json")) as handle:
        meta = json.load(handle)
    names = [c["name"] for c in meta["targets"]]
    pick = [names.index("peakOverpressure"), names.index("firstPhaseImpulse")]
    inputs = np.load(os.path.join(folder, "inputs.npy"))
    ground = np.load(os.path.join(folder, "targets.npy"))[pick]
    mask = np.load(os.path.join(folder, "mask.npy")) > 0
    levels = [("ground", "ground", meta["heightAboveGroundM"])]
    targets = [ground]
    masks = [mask]
    if meta.get("levels"):
        lt = np.load(os.path.join(folder, "levels-targets.npy"))
        lm = np.load(os.path.join(folder, "levels-mask.npy")) > 0
        for n, level in enumerate(meta["levels"]):
            levels.append((level["name"], level["over"], level["metres"]))
            targets.append(lt[n][pick])
            masks.append(lm[n])
    for t, m in zip(targets, masks):
        m &= (t[0] > 10) & (t[1] > 1e-3)
    return {"meta": meta, "inputs": inputs, "levels": levels, "targets": targets, "masks": masks,
            "dx": meta["cellSizeM"]}


def crossings(height, dx, charge):
    """For each plan cell, the number of building cells the line from the charge to it crosses (its
    own and its neighbours' left out), sampled every cell."""
    import numpy as np
    ny, nx = height.shape
    built = height > 0
    cx, cy = charge
    jj, ii = np.mgrid[0:ny, 0:nx]
    x = (ii + 0.5) * dx
    y = (jj + 0.5) * dx
    length = np.hypot(x - cx, y - cy)
    steps = int(length.max() / dx) + 1
    count = np.zeros((ny, nx), np.int32)
    for k in range(steps):
        # The sample k cells out from the charge, on each cell's own line, short of its last 1.5 cells.
        t = np.minimum(1.0, k * dx / np.maximum(length, 1e-6))
        inside = k * dx < length - 1.5 * dx
        si = np.clip(((cx + t * (x - cx)) / dx).astype(np.int64), 0, nx - 1)
        sj = np.clip(((cy + t * (y - cy)) / dx).astype(np.int64), 0, ny - 1)
        count += (built[sj, si] & inside).astype(np.int32)
    return count


def beside(height):
    import numpy as np
    built = height > 0
    near = np.zeros_like(built)
    for dj in (-1, 0, 1):
        for di in (-1, 0, 1):
            near |= np.roll(np.roll(built, dj, 0), di, 1)
    return near & ~built


def front_values(strip, dx, field, mask, outward_tries=1):
    """The mean of `field` (2, H, W) over the cells in front of `strip`, as judge_field.front_cells
    picks them; where the first cell going out is not in the mask, the next one out (up to
    `outward_tries` more)."""
    import numpy as np
    sys.path.insert(0, HERE)
    import judge_field
    rows, cols = judge_field.front_cells(strip, dx, mask.shape)
    axis, outward = int(strip["axis"]), int(strip["outward"])
    step = (0, outward) if axis == 0 else (outward, 0)
    picked_r, picked_c = [], []
    for r, c in zip(rows, cols):
        for k in range(outward_tries + 1):
            rr, cc = r + k * step[0], c + k * step[1]
            if 0 <= rr < mask.shape[0] and 0 <= cc < mask.shape[1] and mask[rr, cc]:
                picked_r.append(rr)
                picked_c.append(cc)
                break
    if not picked_r:
        return None
    return field[:, np.array(picked_r), np.array(picked_c)].mean(axis=1)


def stats(values):
    import numpy as np
    v = np.log(np.asarray(values))
    return (float(np.exp(np.median(v))), float(v.std()), int(v.size)) if v.size else (float("nan"), 0.0, 0)


def analyse(args):
    import numpy as np
    sys.path.insert(0, HERE)
    import judge_field
    rows = []
    for name in sorted(os.listdir(args.out)):
        base = os.path.join(args.out, name)
        if args.tag and not name.endswith("-" + args.tag):
            continue
        if not args.tag and re.search(r"-r[0-9]+$", name):
            continue
        coarse_dir = os.path.join(base, "dx%g" % args.coarse)
        fine_dir = os.path.join(base, "dx%g" % args.fine)
        if not (os.path.exists(os.path.join(coarse_dir, "meta.json"))
                and os.path.exists(os.path.join(fine_dir, "meta.json"))):
            continue
        c, f = load(coarse_dir), load(fine_dir)
        run_id = c["meta"]["id"]
        factor = int(round(c["dx"] / f["dx"]))
        ny, nx = c["targets"][0].shape[1:]
        if f["targets"][0].shape[1:] != (ny * factor, nx * factor):
            print("%s: the grids do not nest (%s, %s)" % (name, c["targets"][0].shape, f["targets"][0].shape))
            continue
        mass = c["meta"]["charge"]["massKg"]
        root = mass ** (1 / 3)
        charge = c["meta"]["charge"]["positionM"][:2]
        z = np.exp(c["inputs"][3])
        height = c["inputs"][0]
        crossed = crossings(height, c["dx"], charge)
        near = beside(height)
        kb = np.stack([c["inputs"][4], c["inputs"][5]])
        fz = np.exp(f["inputs"][3])
        kbf = np.stack([f["inputs"][4], f["inputs"][5]])
        fcrossed = crossings(f["inputs"][0], f["dx"], charge)
        fnear = beside(f["inputs"][0])
        print("%s: %g kt, %d x %d coarse cells; coarse %g m, fine %g m" % (
            run_id, mass / 1e9, nx, ny, c["dx"], f["dx"]), flush=True)
        for li, level in enumerate(c["levels"]):
            ct, cm = c["targets"][li], c["masks"][li]
            ft, fm = f["targets"][li], f["masks"][li]
            blocks = ft.reshape(2, ny, factor, nx, factor)
            bm = fm.reshape(ny, factor, nx, factor).all(axis=(1, 3))
            mean = blocks.mean(axis=(2, 4))
            both = cm & bm
            ratio = mean[:, both] / ct[:, both]
            good = np.all(np.isfinite(ratio) & (ratio > 0), axis=0)
            for n in np.nonzero(good)[0]:
                pass
            sel = np.nonzero(both)
            rows.append({"run": run_id, "kind": "cells", "level": level[0],
                         "z": z[sel][good], "crossed": crossed[sel][good], "near": near[sel][good],
                         "peak": ratio[0][good], "impulse": ratio[1][good]})
            # Each size's open, in-sight cells against Kingery–Bulmash.
            for label, t, m, zz, k, cr, ne in (("coarse", ct, cm, z, kb, crossed, near),
                                               ("fine", ft, fm, fz, kbf, fcrossed, fnear)):
                if level[0] != "ground":
                    continue
                open_ = m & (cr == 0) & ~ne
                rows.append({"run": run_id, "kind": "kb-" + label, "level": level[0], "z": zz[open_],
                             "crossed": cr[open_], "near": ne[open_],
                             "peak": t[0][open_] / k[0][open_], "impulse": t[1][open_] / k[1][open_]})
        # Façades: the run's strips at the level their storey spans.
        strips_path = os.path.join(args.strips, run_id + ".csv")
        if not os.path.exists(strips_path):
            print("  no strips for %s in %s" % (run_id, args.strips))
            continue
        with open(strips_path) as handle:
            strips = [{k: float(v) for k, v in s.items()} for s in csv.DictReader(handle)]
        half = 0.5 * c["meta"]["domainM"][0]
        middle = (0.5 * c["meta"]["domainM"][0], 0.5 * c["meta"]["domainM"][1])
        found = {"peak": [], "impulse": [], "z": [], "level": [], "sight": [], "cos": []}
        for s in strips:
            centre = (0.5 * (s["x0"] + s["x1"]), 0.5 * (s["y0"] + s["y1"]))
            if max(abs(centre[0] - middle[0]), abs(centre[1] - middle[1])) > 0.85 * half:
                continue
            for li, level in enumerate(c["levels"]):
                if level[1] != "ground" or not (s["z0"] <= s["ground"] + level[2] <= s["z1"]):
                    continue
                a = front_values(s, c["dx"], c["targets"][li], c["masks"][li], outward_tries=0)
                b = front_values(s, f["dx"], f["targets"][li], f["masks"][li], outward_tries=factor - 1)
                if a is None or b is None or not np.all((a > 0) & (b > 0)):
                    continue
                found["peak"].append(b[0] / a[0])
                found["impulse"].append(b[1] / a[1])
                found["z"].append(s["distance"] / root)
                found["level"].append(level[0])
                found["sight"].append(judge_field.sight_of(s))
                found["cos"].append(s["cos"])
        rows.append({"run": run_id, "kind": "facades", **{k: np.array(v) for k, v in found.items()}})

    def table(title, chosen, groups):
        print("\n" + title)
        print("  %-28s %9s  %-18s  %-18s" % ("", "count", "peak fine/coarse", "first-phase impulse"))
        for label, pick in groups:
            p, i = [], []
            for r in chosen:
                m = pick(r)
                p.append(r["peak"][m])
                i.append(r["impulse"][m])
            p = np.concatenate(p) if p else np.array([])
            i = np.concatenate(i) if i else np.array([])
            sp, si = stats(p), stats(i)
            if sp[2] == 0:
                continue
            print("  %-28s %9d  %.3f / %.3f       %.3f / %.3f" % (label, sp[2], sp[0], sp[1], si[0], si[1]))
            summary.setdefault(title, []).append({"group": label, "count": sp[2], "peak": sp[:2], "impulse": si[:2]})
        sys.stdout.flush()

    summary = {}
    zgroups = [("Z %g-%g" % (a, b), (lambda a, b: lambda r: (r["z"] >= a) & (r["z"] < b))(a, b))
               for a, b in zip(BANDS, BANDS[1:])]
    every = [("all", lambda r: np.ones(r["z"].shape, bool))]
    cells = [r for r in rows if r["kind"] == "cells"]
    for level in sorted({r["level"] for r in cells}, key=lambda n: (n != "ground", n != "roof", n)):
        chosen = [r for r in cells if r["level"] == level]
        table("Cells at %s: fine over coarse, by scaled distance" % level, chosen, every + zgroups)
        table("Cells at %s: by sight" % level, chosen, [
            ("in sight, open", lambda r: (r["crossed"] == 0) & ~r["near"]),
            ("in sight, beside a building", lambda r: (r["crossed"] == 0) & r["near"]),
            ("shielded 1-3, open", lambda r: (r["crossed"] >= 1) & (r["crossed"] <= 3) & ~r["near"]),
            ("shielded 4+, open", lambda r: (r["crossed"] >= 4) & ~r["near"]),
            ("shielded, beside a building", lambda r: (r["crossed"] >= 1) & r["near"])])
    for label in ("coarse", "fine"):
        chosen = [r for r in rows if r["kind"] == "kb-" + label]
        table("Open, in-sight cells at 2 m, %s over Kingery-Bulmash" % label, chosen, every + zgroups)
    facades = [r for r in rows if r["kind"] == "facades" and r["z"].size]
    for level in sorted({lv for r in facades for lv in r["level"]}, key=lambda n: (n != "ground", n)):
        chosen = [dict(r, z=r["z"][r["level"] == level], peak=r["peak"][r["level"] == level],
                       impulse=r["impulse"][r["level"] == level], sight=r["sight"][r["level"] == level],
                       cos=r["cos"][r["level"] == level]) for r in facades]
        table("Facade strips at %s: fine over coarse, by scaled distance" % level, chosen, every + zgroups)
        table("Facade strips at %s: by sight" % level, chosen, [
            (name, (lambda name: lambda r: r["sight"] == name)(name)) for name in
            ("in sight, facing", "shielded, 1-3 crossed", "shielded, 4+ crossed", "street to the charge",
             "facing away")] + [("face-on, open (cos > 0.7)", lambda r: (r["cos"] > 0.7) & (r["sight"] == "in sight, facing"))])
    by_run = [("%s" % r["run"], (lambda rid: lambda x: np.full(x["z"].shape, x["run"] == rid))(r["run"]))
              for r in rows if r["kind"] == "cells" and r["level"] == "ground"]
    table("Cells at ground, by run", [r for r in cells if r["level"] == "ground"], by_run)
    table("Facade strips at ground, by run", [dict(r, z=r["z"][r["level"] == "ground"],
                                                   peak=r["peak"][r["level"] == "ground"],
                                                   impulse=r["impulse"][r["level"] == "ground"]) for r in facades],
          by_run)
    if args.json:
        with open(args.json, "w") as handle:
            json.dump(summary, handle, indent=1)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--only", required=True)
    r.add_argument("--dx", default="4,2")
    r.add_argument("--out", required=True)
    r.add_argument("--radius", type=int)
    r.add_argument("--tag", default="")
    r.add_argument("--levels", default="6,10,14,20")
    r.add_argument("--scenebench", default=os.path.join(REPOSITORY, ".build", "release", "scenebench"))
    r.add_argument("--dry-run", action="store_true")
    a = sub.add_parser("analyse")
    a.add_argument("--out", required=True)
    a.add_argument("--coarse", type=float, default=4)
    a.add_argument("--fine", type=float, default=2)
    a.add_argument("--tag", default="")
    a.add_argument("--strips", default=STRIPS)
    a.add_argument("--json")
    args = parser.parse_args(argv)
    return run(args) if args.command == "run" else analyse(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
