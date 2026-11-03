#!/usr/bin/env python3
"""The reference corpus: the next runs chosen where the learned models are least sure
(emmettl/bombcad-work#118; docs/learned-models.md, "Choosing the next runs").

    $PY Scripts/ml/corpus.py pool DIR [--seeds 2]            # candidates and their districts
    $PY Scripts/ml/corpus.py probe DIR [--jobs 3]            # a few cheap frames of each
    $PY Scripts/ml/corpus.py select DIR --base FOLDERS --members A.bclr,B.bclr,… --budget 3
    $PY Scripts/ml/corpus.py check DIR --base … --members …  # the held-out scenes, scored
    $PY Scripts/ml/corpus.py round DIR --list active,fixed [--jobs 3]   # label the lists
    $PY Scripts/ml/corpus.py pack DIR --base-pack PACK --out PACK2      # one dataset to send
    $PY Scripts/ml/corpus.py judge --model name=file.bclr … --set name=folder[,folder][@held] …
    $PY Scripts/ml/corpus.py audit DIR --members …           # did the scores find the errors?
    $PY Scripts/ml/corpus.py needs                           # what each model needs from a run
    $PY Scripts/ml/corpus.py ranges --base FOLDERS --weights W.bclr   # the built-in weights' ranges (the drag and its test)

For the live drag's learned response (`train_response.py`'s three networks). A candidate is one
piece of `scenebench response-data`: a made-up district (`make_district.py`, a style and a seed),
its cells, the charges' range and how far from the middle they fall. `probe` runs each candidate
for a few frames on two draws (the inputs are as a full piece's; only the walls' and glass's
chances are rough). `select` scores each candidate's probe rows against the networks' training:

- **novelty**: each row's distance, in the networks' standardised inputs, to the nearest of a
  sample of the training's rows, over the 90th percentile of the same for the training's own
  held-out frames (so 1 is as far as the held-out rows go); and each feature's reach beyond the
  training's 0.1-99.9% range, which names the inputs the training never moved;
- **scatter**: the spread of an ensemble's answers (the networks trained again from other seeds),
  over its 90th percentile on the held-out frames.

A row's value is what each exceeds 1 by (each held to 10), the candidate's value its rows' sum
scaled to a labelled piece's frames, a unit's rows counted against the training's rows a frame.
Candidates are taken greedily by value over cost (the probe's CPU time scaled to a labelled
piece, `LABEL_OVER_PROBE`) until the budget is spent; each taken candidate's probe rows then count as seen, so rows
within the held-out distance of them are worth nothing more (a candidate like one taken is
worth less). `select` writes the active list and a fixed list of the same budget, drawn from the
same pool without the models (one of each kind of candidate in a seeded order, then the next).

$PY is a Python with NumPy (on the Studio, `$BOMBCAD_DATA/ml/venv/bin/python -I`); nothing more is
needed: the weights are read from the float32 `.bclr` files `train_response.py` writes.
"""

import argparse
import concurrent.futures
import gzip
import importlib.util
import json
import math
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
GPU_SLOT = os.path.expanduser("~/.local/bin/gpu-slot")
UNITS = ("component", "side", "building")
LEVELS = 5
SHAPE = ["kind.facade", "kind.wall", "kind.slab", "kind.roof", "kind.pane", "span.short", "span.long",
         "oneWaySpan", "oneWay", "freestanding", "edge0", "edge1", "edge2", "edge3", "axisZ",
         "panelHeight", "above", "below"]
SLOT = ["load%d" % k for k in range(6)] + ["lnZ", "present", "scatter.peak", "scatter.impulse",
                                           "scatter.correlation"] + ["facing%d" % k for k in range(6)] + SHAPE
CENTRE = 1200 / (6_371_008.8 * math.pi / 180)  # make_district's middle at its default 2,400 m extent

# The candidates' kinds: a style of made-up district on cells of `dx`, its charges' range (kg), the
# square of half side `radius` laid out, charges within `within` of the middle.
CONFIGS = {
    "4m-wide": {"dx": 4, "masses": [100, 5e6], "radius": 1100, "within": 900, "clear": 100, "mass": 100000},
    "4m-small": {"dx": 4, "masses": [50, 5000], "radius": 300, "within": 250, "clear": 0, "mass": 500},
    "2m-small": {"dx": 2, "masses": [50, 5000], "radius": 300, "within": 250, "clear": 0, "mass": 500},
    "2m-mid": {"dx": 2, "masses": [1000, 100000], "radius": 300, "within": 250, "clear": 0, "mass": 10000},
    # The explorer's Beirut is on 6 m cells (emmettl/bombcad-work#118): `pool --configs 6m-wide`.
    "6m-wide": {"dx": 6, "masses": [100, 5e6], "radius": 1100, "within": 900, "clear": 100, "mass": 100000},
}
# Stage 1's pool: the kinds `pool` makes unless `--configs` names others.
POOL_CONFIGS = "4m-wide,4m-small,2m-small,2m-mid"
STYLES = ("perimeter", "grid", "towers", "industrial", "square")  # mixed is held out, as since round 4
TERRAINS = ("flat", "slope", "hill", "valley")


def scenebench():
    return os.environ.get("SCENEBENCH") or str(REPO / ".build" / "release" / "scenebench")


# MARK: - The pool


def pool(args):
    """Every kind (style × config) `--seeds` times, each its own seed and terrain (the squares flat,
    as the explorer's). Seeds from `--first-seed` (31) on, clear of the training's (1-4, 7) and the
    squares' 1-24; stage 1's pool took 31-70. `--explorer NAME DX` adds the explorer's scene on cells
    of DX m as a held-out scene (`scenebench response-data --explorer`), charges of 100 kg to 5 kt within
    900 m."""
    spec = importlib.util.spec_from_file_location("make_district", HERE / "make_district.py")
    make_district = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(make_district)
    root = Path(args.dir)
    candidates = []
    n = 0
    configs = {name: CONFIGS[name] for name in args.configs.split(",")}
    for k in range(args.seeds):
        for config, c in configs.items():
            for s, style in enumerate(STYLES):
                seed = args.first_seed + n
                terrain = "flat" if style == "square" else TERRAINS[n % len(TERRAINS)]
                radius = 300 if style == "square" else c["radius"]
                within = min(c["within"], 250) if style == "square" else c["within"]
                folder = root / "districts" / ("%s-%d" % (style, seed))
                made = make_district.write(str(folder), style, seed, 2400, terrain)
                candidates.append({
                    "id": "%s-%s-s%d" % (style, config, seed), "kind": "%s/%s" % (style, config),
                    "style": style, "config": config, "seed": seed, "terrain": terrain,
                    "osm": made["osm"], "dem": made["dem"], "centre": made["centre"], "buildings": made["buildings"],
                    "dx": c["dx"], "radius": radius, "within": within, "clear": c["clear"],
                    "masses": c["masses"], "mass": c["mass"], "index": n})
                n += 1
    scenes = []
    for name, osm in (args.scene or []):
        scenes.append({"id": name, "kind": "held-out", "osm": osm, "dem": None, "centre": [0, 0], "dx": 2,
                       "radius": 300, "within": 250, "clear": 0, "masses": [50, 5000], "mass": 500,
                       "index": 900 + len(scenes), "heldOut": True})
    for name, dx in (args.explorer or []):
        scenes.append({"id": "explorer-%s-%sm" % (name, dx), "kind": "held-out", "explorer": name, "dx": float(dx),
                       "radius": 1500, "within": 900, "clear": 0, "masses": [100, 5e6], "mass": 500000,
                       "index": 900 + len(scenes), "heldOut": True})
    # The held-out made-up district of round 4 on (mixed blocks, a quarter turned, in a valley; seed
    # 7), on 4 m cells as it was judged and on 2 m cells within 300 m: a style no candidate has.
    made = make_district.write(str(root / "districts" / "mixed-7"), "mixed", 7, 2400, "valley")
    for config in ("4m-wide", "2m-small"):
        c = CONFIGS[config]
        scenes.append({"id": "mixed-7-" + config, "kind": "held-out", "osm": made["osm"], "dem": made["dem"],
                       "centre": made["centre"], "dx": c["dx"], "radius": c["radius"], "within": c["within"],
                       "clear": c["clear"], "masses": c["masses"], "mass": c["mass"], "index": 900 + len(scenes),
                       "heldOut": True})
    plan = {"version": 1, "probe": {"frames": args.probe_frames, "draws": 2, "keep": 1},
            "label": {"frames": args.label_frames, "draws": 32}, "candidates": candidates, "scenes": scenes}
    (root / "pool.json").write_text(json.dumps(plan, indent=1))
    print("%d candidates of %d kinds, %d held-out scenes, in %s" % (
        len(candidates), len({c["kind"] for c in candidates}), len(scenes), root / "pool.json"))


def load_pool(folder):
    return json.loads((Path(folder) / "pool.json").read_text())


def command(c, out, frames, draws, seed, keep=None):
    where = (["--explorer", c["explorer"]] if c.get("explorer")
             else ["--osm", c["osm"], "--centre", "%r,%r" % tuple(c["centre"])])
    cmd = [scenebench(), "response-data"] + where + [
           "--dx", "%g" % c["dx"], "--radius", str(c["radius"]), "--mass", str(c["mass"]),
           "--district", c["id"], "--out", str(out), "--frames", str(frames), "--draws", str(draws),
           "--within", str(c["within"]), "--clear", str(c["clear"]), "--masses", "%g,%g" % tuple(c["masses"]),
           "--seed", str(seed)]
    if c.get("dem"):
        cmd += ["--dem", c["dem"]]
    if keep is not None:
        cmd += ["--keep", str(keep)]
    return cmd


def memory_gb(c, label):
    """What to declare to gpu-slot: the 4 m pieces over 1.1 km held 4-7 GB on 32 draws (what-ifs, this pool)."""
    if c["radius"] > 600:
        return 6 if label else 4
    return 2


def run_jobs(jobs, parallel):
    """[(name, cmd, log, mem)] under gpu-slot at a nice of 10, `parallel` at a time; each log ends with
    `/usr/bin/time -l`'s lines, which `cost` reads."""
    def one(job):
        name, cmd, log, mem = job
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "w") as handle:
            code = subprocess.call([GPU_SLOT, "--mem", str(mem), "/usr/bin/time", "-l", "nice", "-n", "10"] + cmd,
                                   stdout=handle, stderr=subprocess.STDOUT)
        print("%s: exit %d" % (name, code), flush=True)
        return code
    with concurrent.futures.ThreadPoolExecutor(parallel) as pool_:
        return list(pool_.map(one, jobs))


def cost(log):
    """A finished piece's CPU seconds (user + system), its peak memory (GB) and its frames' stage times
    (inputs, damage, glass, walls; wall seconds), from its log."""
    text = Path(log).read_text() if Path(log).exists() else ""
    m = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", text)
    rss = re.search(r"(\d+)\s+maximum resident set size", text)
    stages = [tuple(float(v) for v in s) for s in
              re.findall(r"inputs ([\d.]+) s, damage ([\d.]+) s, glass ([\d.]+) s, walls ([\d.]+) s", text)]
    if not m:
        return None
    return {"real": float(m.group(1)), "cpu": float(m.group(2)) + float(m.group(3)),
            "gb": int(rss.group(1)) / 1e9 if rss else None, "stages": stages}


def probe(args):
    root = Path(args.dir)
    plan = load_pool(root)
    p = plan["probe"]
    jobs = []
    for c in plan["candidates"] + plan["scenes"]:
        out = root / "probes" / c["id"]
        if (out / "meta.json").exists() and cost(root / "logs" / ("probe-" + c["id"] + ".log")):
            continue
        jobs.append((c["id"], command(c, out, p["frames"], p["draws"], 9000 + c["index"], p["keep"]),
                     root / "logs" / ("probe-" + c["id"] + ".log"), memory_gb(c, False)))
    print("%d probes to run" % len(jobs), flush=True)
    run_jobs(jobs, args.jobs)


# A labelled frame's CPU time (32 draws) over a probe's (2 draws), measured on the pieces of rounds 4
# and 6 against this pool's probes of the same styles: 3.3-5.2 over 1.1 km on 4 m cells (perimeter,
# grid, towers; industrial 6.6), 6.5 for a 2 m square within 300 m. Within about 40%.
LABEL_OVER_PROBE = {"wide": 4.7, "small": 6.5}


def estimated_cost(root, plan, c):
    """A labelled piece's CPU seconds, from its probe's: per frame, times `LABEL_OVER_PROBE`."""
    probe_cost = cost(root / "logs" / ("probe-" + c["id"] + ".log"))
    if not probe_cost or not probe_cost["stages"]:
        return None
    ratio = LABEL_OVER_PROBE["wide" if c["radius"] > 600 else "small"]
    return probe_cost["cpu"] * ratio * plan["label"]["frames"] / len(probe_cost["stages"])


def round_(args):
    """Label the lists' candidates (each once, however many lists take it), or with `--scenes` the
    held-out scenes, for judging."""
    root = Path(args.dir)
    plan = load_pool(root)
    by_id = {c["id"]: c for c in plan["candidates"] + plan["scenes"]}
    ids = []
    for name in args.list.split(",") if args.list else []:
        ids += json.loads((root / ("%s.json" % name)).read_text())["picked"]
    if args.scenes:
        ids += [s["id"] for s in plan["scenes"]]
    if args.all:
        ids += [c["id"] for c in plan["candidates"]]
    jobs = []
    lab = plan["label"]
    for i in dict.fromkeys(ids):
        c = by_id[i]
        out = root / "labels" / i
        log = root / "logs" / ("label-" + i + ".log")
        if (out / "meta.json").exists() and cost(log):
            continue
        frames = args.scene_frames if c.get("heldOut") else lab["frames"]
        jobs.append((i, command(c, out, frames, lab["draws"], 100 + c["index"]), log, memory_gb(c, True)))
    # The cheapest first, so that a stopped round has the most pieces done.
    jobs.sort(key=lambda j: estimated_cost(root, plan, by_id[j[0]]) or 0)
    print("%d pieces to label" % len(jobs), flush=True)
    run_jobs(jobs, args.jobs)


def pack(args):
    """A dataset of the base's pack (hard links) and the labelled pieces gzipped, as remote-train.py
    sends one folder; `train_response.py --only` picks a round's folders from it."""
    root = Path(args.dir)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    base = Path(args.base_pack)
    for folder in sorted(p for p in base.iterdir() if (p / "meta.json").exists()):
        (out / folder.name).mkdir(exist_ok=True)
        for f in folder.iterdir():
            target = out / folder.name / f.name
            if not target.exists():
                os.link(f, target)
    plan = load_pool(root)
    held = {s["id"] for s in plan["scenes"]}
    for folder in sorted((root / "labels").iterdir()):
        if folder.name in held or not (folder / "meta.json").exists():
            continue  # the held-out scenes never go
        (out / folder.name).mkdir(exist_ok=True)
        for f in folder.iterdir():
            if f.suffix in (".f32", ".i32"):
                target = out / folder.name / (f.name + ".gz")
                if not target.exists():
                    with open(f, "rb") as src, gzip.open(target, "wb", compresslevel=1) as dst:
                        dst.write(src.read())
            elif f.name == "meta.json":
                (out / folder.name / f.name).write_bytes(f.read_bytes())
    print("packed in %s" % out)


# MARK: - Weights and rows


class Net:
    """One of `LiveResponse.Weights`' networks: dense layers, SiLU between, inputs standardised."""

    def __init__(self, entry, blob):
        self.mean = np.array(entry["mean"], dtype=np.float64)
        self.std = np.array(entry["std"], dtype=np.float64)
        self.layers = []
        for layer in entry["layers"]:
            i, o, at = layer["inputs"], layer["outputs"], layer["offset"]
            self.layers.append((blob[at:at + i * o].reshape(o, i), blob[at + i * o:at + i * o + o]))

    def standardised(self, x):
        return ((x - self.mean) / self.std).astype(np.float32)

    def __call__(self, x):
        h = self.standardised(x)
        for n, (w, b) in enumerate(self.layers):
            h = h @ w.T + b
            if n < len(self.layers) - 1:
                h = h / (1 + np.exp(-np.clip(h, -60, 60)))
        return h


def read_bclr(path):
    data = Path(path).read_bytes()
    assert data[:4] == b"BCLR", "%s is not a live response's weights" % path
    _, length = struct.unpack("<II", data[4:12])
    header = json.loads(data[12:12 + length])
    dtype = np.float16 if header.get("dtype") == "float16" else np.float32
    blob = np.frombuffer(data[12 + length:], dtype=dtype).astype(np.float32)
    return {name: Net(entry, blob) for name, entry in header["networks"].items()}


def quantised(x):
    """As train_response.py rounds the component rows' load."""
    x = np.array(x, dtype=np.float32)
    step = math.log10(1.03)
    x[:, 0] = np.round(x[:, 0].astype(np.float64) / step) * step
    x[:, 1] = np.round(x[:, 1].astype(np.float64) / step) * step
    x[:, 2] = np.round(x[:, 2].astype(np.float64) * 20) / 20
    return x


def array(folder, name, dtype, width=None):
    path = Path(folder) / name
    if path.exists():
        a = np.memmap(path, dtype=dtype, mode="r") if path.stat().st_size else np.zeros(0, dtype)
    elif (Path(folder) / (name + ".gz")).exists():
        with gzip.open(Path(folder) / (name + ".gz"), "rb") as f:
            a = np.frombuffer(f.read(), dtype=dtype)
    else:
        a = np.zeros(0, dtype)
    return a.reshape(-1, width) if width else a


def widths(folder):
    meta = json.loads((Path(folder) / "meta.json").read_text())
    return {"component": meta["componentWidth"], "side": meta["sideWidth"], "building": meta["buildingWidth"],
            "thrown": meta["sideWidth"]}, meta


def rows(folder, unit, held=None, limit=None, rng=None):
    """A folder's rows of one unit: inputs, answers, weights, frames. `held` True keeps the frames 9
    modulo 10 alone, False the rest; `limit` draws that many rows in proportion to their weights
    (each then weighing the same)."""
    width, meta = widths(folder)
    answers = {"component": 2, "side": len(meta["sideOutputs"]), "building": len(meta["buildingOutputs"]),
               "thrown": len(meta.get("thrownOutputs", []))}[unit]
    x = array(folder, unit + "-x.f32", np.float32, width[unit])
    y = array(folder, unit + "-y.f32", np.float32, answers)
    w = array(folder, unit + "-w.f32", np.float32)
    frame = array(folder, unit + "-frame.i32", np.int32)
    n = min(len(x), len(y), len(w), len(frame))
    pick = np.arange(n)
    if held is not None:
        pick = pick[(np.asarray(frame[:n]) % 10 == 9) == held]
    weights = np.asarray(w)[pick].astype(np.float64)
    if limit is not None and len(pick) > limit:
        rng = rng or np.random.default_rng(1)
        chosen = np.sort(rng.choice(len(pick), size=limit, replace=True, p=weights / weights.sum()))
        pick = pick[chosen]
        weights = np.full(len(pick), weights.sum() / limit)
    xs = np.asarray(x[pick], dtype=np.float32)
    if unit == "component":
        xs = quantised(xs)
    return xs, np.asarray(y[pick], dtype=np.float32), weights, np.asarray(frame[pick])


def sigmoid(z):
    return 1 / (1 + np.exp(-np.clip(z, -60, 60)))


def answers(unit, out):
    """A network's raw outputs as chances: the components' five levels and glass, the others' sigmoids."""
    if unit == "component":
        z = out[:, :LEVELS] - out[:, :LEVELS].max(1, keepdims=True)
        p = np.exp(z)
        p /= p.sum(1, keepdims=True)
        return np.concatenate([p, sigmoid(out[:, LEVELS:LEVELS + 1])], 1)
    return sigmoid(out)


def scatter(unit, members, x):
    """Each row's spread over the ensemble: the standard deviation of the expected level (over the
    four steps) and of the glass's chance for a component, of each chance for the others; the
    largest."""
    outs = np.stack([answers(unit, m[unit](x)) for m in members])
    if unit == "component":
        level = (outs[:, :, :LEVELS] * np.arange(LEVELS)).sum(2) / (LEVELS - 1)
        return np.maximum(level.std(0), outs[:, :, LEVELS].std(0))
    return outs.std(0).max(1)


def nearest(q, ref, chunk=1024):
    """Each of q's rows' Euclidean distance to its nearest row of ref."""
    if len(ref) == 0:
        return np.full(len(q), np.inf)
    rr = (ref.astype(np.float64) ** 2).sum(1)
    out = np.empty(len(q))
    ref32 = ref.astype(np.float32)
    for s in range(0, len(q), chunk):
        a = q[s:s + chunk].astype(np.float32)
        d2 = (a.astype(np.float64) ** 2).sum(1)[:, None] + rr[None, :] - 2 * (a @ ref32.T).astype(np.float64)
        out[s:s + chunk] = np.sqrt(np.maximum(d2.min(1), 0))
    return out


def feature_names(unit, width):
    if unit == "component":  # its load, its construction, then its shape (`LiveResponse.batch`)
        names = ["log10Peak", "log10Impulse", "rise"]
        return names + construction_names(width - len(names) - len(SHAPE)) + SHAPE
    elif unit == "building":
        names = ["%s.%s" % ("roof" if j == 8 else "wall%d" % j, f) for j in range(9) for f in SLOT] + ["yieldLogSD"]
    else:  # the glass's, and the thrown network's, which reads the same
        names = ["strip%d.%s" % (j, f) for j in range(4) for f in ["load%d" % k for k in range(6)] +
                 ["share", "lnDistance", "present"]] + ["log10Area", "yieldLogSD", "scatter.peak",
                                                        "scatter.impulse", "scatter.correlation"]
    left = width - len(names)
    if unit in ("side", "thrown"):  # `LiveResponse.glazingFeatures`: the map mix, then the glass
        return names + ["glazing.mix%d" % k for k in range(4)] + ["glazing.glass%d" % k for k in range(left - 4)]
    return names + construction_names(left)


def construction_names(width):
    """`LiveResponse.constructionFeatures`' inputs."""
    return (["walls.kind%d" % k for k in range(5)] + ["walls.thickness"] + ["roof.kind%d" % k for k in range(5)]
            + ["roof.thickness", "bars", "glass.mm", "glass.plain"] + ["glass%d" % k for k in range(width - 19)]
            + ["facadePane.x", "facadePane.y", "facadePane.set", "spare"])[:width]


class Reference:
    """What the networks were trained on, per unit: a weighted sample of the training's rows,
    standardised as the networks standardise them; the 0.1-99.9% range of each input; and the
    held-out frames' 90th percentiles of distance and of the ensemble's scatter."""

    def __init__(self, folders, members, sample=40000, held_sample=4000, seed=1):
        rng = np.random.default_rng(seed)
        self.members = members
        self.units = {}
        for unit in UNITS:
            parts, held_parts, frames, total = [], [], 0, 0.0
            for f in folders:
                x, _, w, fr = rows(f, unit, held=False)
                if not len(x):
                    continue
                parts.append((x, w))
                frames += len(np.unique(fr))
                total += w.sum()
                hx, _, hw, _ = rows(f, unit, held=True)
                held_parts.append((hx, hw))
            x = np.concatenate([p[0] for p in parts])
            w = np.concatenate([p[1] for p in parts])
            hx = np.concatenate([p[0] for p in held_parts])
            hw = np.concatenate([p[1] for p in held_parts])
            net = members[0][unit]
            pick = rng.choice(len(x), size=min(sample, len(x)), replace=False, p=w / w.sum())
            ref = net.standardised(x[pick])
            # The range over a larger sample, so that a rare value the training has is not out of it.
            big = net.standardised(x[rng.choice(len(x), size=min(20 * sample, len(x)), replace=False, p=w / w.sum())])
            lo, hi = np.quantile(big, 0.001, axis=0), np.quantile(big, 0.999, axis=0)
            hpick = rng.choice(len(hx), size=min(held_sample, len(hx)), replace=False, p=hw / hw.sum())
            hz = net.standardised(hx[hpick])
            d = nearest(hz, ref)
            s = scatter(unit, members, hx[hpick])
            self.units[unit] = {"ref": ref, "lo": lo, "hi": hi, "distance90": float(np.quantile(d, 0.9)),
                                "scatter90": max(float(np.quantile(s, 0.9)), 1e-3),
                                "rowsPerFrame": total / max(frames, 1), "names": feature_names(unit, ref.shape[1])}
            print("reference %s: %d rows of %d (%d frames), held-out distance p90 %.3f, scatter p90 %.4f" % (
                unit, len(ref), len(x), frames, self.units[unit]["distance90"], self.units[unit]["scatter90"]),
                flush=True)

    def score(self, folder, limit=3000, seed=2):
        """A probe's rows against the training: per unit the standardised rows, each row's novelty,
        reach out of range and scatter (each over the held-out's 90th percentile), the weights, and
        the features most out of range."""
        rng = np.random.default_rng(seed)
        result = {}
        for unit in UNITS:
            x, y, w, fr = rows(folder, unit)
            frames = max(len(np.unique(fr)), 1)
            if not len(x):
                result[unit] = None
                continue
            total = w.sum()
            if len(x) > limit:
                pick = np.sort(rng.choice(len(x), size=limit, replace=False, p=w / w.sum()))
                x, y, fr = x[pick], y[pick], fr[pick]
                w = np.full(limit, total / limit)
            u = self.units[unit]
            z = self.members[0][unit].standardised(x)
            novelty = nearest(z, u["ref"]) / u["distance90"]
            beyond = np.maximum(np.maximum(z - u["hi"], u["lo"] - z), 0)
            spread = scatter(unit, self.members, x) / u["scatter90"]
            worst = beyond.mean(0)
            top = [(u["names"][k], float(worst[k]), float((beyond[:, k] > 1).mean())) for k in np.argsort(-worst)[:3]
                   if worst[k] > 0.05]
            result[unit] = {"z": z, "novelty": novelty, "beyond": beyond.max(1), "scatter": spread, "w": w,
                            "frames": frames, "x": x, "y": y, "top": top}
        return result


def row_value(s, cap=10.0):
    return np.minimum(np.maximum(s["novelty"] - 1, 0), cap) + np.minimum(np.maximum(s["scatter"] - 1, 0), cap)


def summary(s, unit_ref):
    if s is None:
        return None
    w = s["w"] / s["w"].sum()
    return {"novelty": float((s["novelty"] * w).sum()), "novel": float(((s["novelty"] > 1) * w).sum()),
            "outOfRange": float(((s["beyond"] > 1) * w).sum()), "scatter": float((s["scatter"] * w).sum()),
            "unsure": float(((s["scatter"] > 1) * w).sum()), "features": s["top"]}


def greedy(candidates, values, costs, budget, seen_distance):
    """Take candidates by value over cost while the budget lasts. `values[c][unit]` is (row values, row
    weights, scale, standardised rows); after each take, rows within the held-out distance of its rows
    are worth nothing, rising to their whole value at twice it. `seen_distance[unit]` is that distance.
    Returns the picks and each pick's value when taken."""
    remaining = budget
    left = [c for c in candidates if costs.get(c) is not None]
    cover = {c: {u: np.ones(len(v[0])) for u, v in values[c].items()} for c in left}
    picks = []
    while True:
        def worth(c):
            return sum(scale * float((rv * wt * cover[c][u]).sum()) for u, (rv, wt, scale, _) in values[c].items())
        fits = [c for c in left if costs[c] <= remaining]
        if not fits:
            break
        best = max(fits, key=lambda c: (worth(c) / costs[c], -costs[c]))
        picks.append((best, worth(best)))
        remaining -= costs[best]
        left.remove(best)
        for c in left:
            for u, (rv, wt, scale, z) in values[c].items():
                if u in values[best] and len(values[best][u][3]) and len(z):
                    d = nearest(z, values[best][u][3]) / seen_distance[u]
                    cover[c][u] = np.minimum(cover[c][u], np.clip(d - 1, 0, 1))
    return picks


def fixed_list(plan, costs, budget, seed=7):
    """Without the models: the pool's kinds in a seeded order, one candidate of each, then the next
    of each, taken while the budget lasts."""
    rng = np.random.default_rng(seed)
    kinds = sorted({c["kind"] for c in plan["candidates"]})
    order = [kinds[k] for k in rng.permutation(len(kinds))]
    by_kind = {k: [c["id"] for c in plan["candidates"] if c["kind"] == k] for k in kinds}
    sequence = [ids[n] for n in range(max(len(v) for v in by_kind.values())) for k in order
                for ids in [by_kind[k]] if n < len(ids)]
    picks, remaining = [], budget
    for c in sequence:
        if costs.get(c) is not None and costs[c] <= remaining:
            picks.append(c)
            remaining -= costs[c]
    return picks


def members_from(text):
    return [read_bclr(p) for p in text.split(",")]


def base_folders(text):
    out = []
    for part in text.split(","):
        path = Path(part)
        out += [path] if (path / "meta.json").exists() else sorted(p for p in path.iterdir() if (p / "meta.json").exists())
    return out


def scored(root, plan, reference, ids, label_frames):
    values, report = {}, {}
    for c in ids:
        folder = root / "probes" / c
        if not (folder / "meta.json").exists():
            continue
        s = reference.score(folder)
        values[c] = {}
        report[c] = {}
        for u in UNITS:
            if s[u] is None:
                continue
            scale = label_frames / s[u]["frames"] / reference.units[u]["rowsPerFrame"] / len(UNITS)
            values[c][u] = (row_value(s[u]), s[u]["w"], scale, s[u]["z"])
            report[c][u] = summary(s[u], reference.units[u])
            report[c][u]["value"] = scale * float((row_value(s[u]) * s[u]["w"]).sum())
            if u == "component":
                # The probe's own answers for the components are exact (no draws): the first
                # member's error on them, for `audit` (the selection does not use it).
                out = reference.members[0][u](s[u]["x"])
                wn = s[u]["w"] / s[u]["w"].sum()
                report[c][u]["levelExact"] = float(((out[:, :LEVELS].argmax(1) == s[u]["y"][:, 0]) * wn).sum())
    return values, report


def select(args):
    root = Path(args.dir)
    plan = load_pool(root)
    members = members_from(args.members)
    folders = base_folders(args.base)
    reference = Reference(folders, members, sample=args.sample)
    # A candidate already in the training is not a candidate.
    ids = [c["id"] for c in plan["candidates"] if c["id"] not in {f.name for f in folders}]
    values, report = scored(root, plan, reference, ids, plan["label"]["frames"])
    costs = {c["id"]: estimated_cost(root, plan, c) for c in plan["candidates"]}
    budget = args.budget * 3600
    seen = {u: 1.0 for u in UNITS}  # distances are already over the held-out's 90th percentile
    picks = greedy([c for c in ids if c in values], values, costs, budget, seen)
    costs = {c: v for c, v in costs.items() if c in ids}
    fixed = fixed_list(plan, costs, budget, args.fixed_seed)
    ranking = sorted(values, key=lambda c: -sum(r["value"] for r in report[c].values()) / max(costs[c] or 1, 1))
    out = {"budgetCPUHours": args.budget, "members": args.members.split(","), "base": args.base,
           "candidates": {c: {"kind": next(x["kind"] for x in plan["candidates"] if x["id"] == c),
                              "estimatedCPUSeconds": costs[c], "units": report[c],
                              "value": sum(r["value"] for r in report[c].values())} for c in values},
           "ranking": ranking}
    (root / ("selection%s.json" % args.tag)).write_text(json.dumps(out, indent=1))
    spent = sum(costs[c] for c, _ in picks)
    (root / ("active%s.json" % args.tag)).write_text(json.dumps({"picked": [c for c, _ in picks], "valueWhenTaken": dict(picks),
                                                  "estimatedCPUSeconds": spent}, indent=1))
    (root / ("fixed%s.json" % args.tag)).write_text(json.dumps({"picked": fixed, "estimatedCPUSeconds": sum(costs[c] for c in fixed)},
                                                indent=1))
    print_ranking(out, plan)
    print("\nactive (%.2f CPU h): %s" % (spent / 3600, ", ".join(c for c, _ in picks)))
    print("fixed  (%.2f CPU h): %s" % (sum(costs[c] for c in fixed) / 3600, ", ".join(fixed)))


def print_ranking(out, plan):
    print("\n| Rank | Candidate | Value / CPU h | Value | Novel rows (comp / side / bldg) | Scatter (comp / side / bldg) | Out of range, most |")
    print("|---|---|---|---|---|---|---|")
    for n, c in enumerate(out["ranking"]):
        r = out["candidates"][c]
        u = r["units"]

        def three(key, fmt):
            return " / ".join(fmt % u[k][key] if k in u else "–" for k in UNITS)
        feats = sorted(((f, m) for k in u for f, m, _ in u[k]["features"]), key=lambda t: -t[1])[:2]
        print("| %d | %s | %.1f | %.1f | %s | %s | %s |" % (
            n + 1, c, r["value"] / max((r["estimatedCPUSeconds"] or 1) / 3600, 1e-9), r["value"],
            three("novel", "%.2f"), three("scatter", "%.2f"),
            ", ".join("%s %.1f" % f for f in feats) or "–"))


def check(args):
    """The held-out scenes (or any probe folders) scored as candidates are, never taken."""
    root = Path(args.dir)
    plan = load_pool(root)
    members = members_from(args.members)
    reference = Reference(base_folders(args.base), members, sample=args.sample)
    ids = [s["id"] for s in plan["scenes"]] + (args.also.split(",") if args.also else [])
    _, report = scored(root, plan, reference, ids, plan["label"]["frames"])
    for c in report:
        print("\n%s" % c)
        for u, r in report[c].items():
            print("  %s: novel rows %.2f (mean novelty %.2f), out of range %.2f, scatter %.2f (unsure rows %.2f), "
                  "value %.1f%s; most out of range: %s" % (
                      u, r["novel"], r["novelty"], r["outOfRange"], r["scatter"], r["unsure"], r["value"],
                      ", level exact %.4f" % r["levelExact"] if "levelExact" in r else "",
                      ", ".join("%s %.1f (%.0f%% of rows)" % (f, m, 100 * share) for f, m, share in r["features"]) or "none"))
    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=1))


# MARK: - Judging


def measures(unit, net, folder, held):
    x, y, w, _ = rows(folder, unit, held=held)
    if not len(x):
        return None, 0
    out = np.concatenate([net[unit](x[s:s + 65536]) for s in range(0, len(x), 65536)])
    wn = w / w.sum()
    if unit == "component":
        level = out[:, :LEVELS].argmax(1)
        exact = level == y[:, 0]
        damaged = y[:, 0] > 0
        return {"levelExact": float((exact * wn).sum()),
                "levelExactWhereDamaged": float((exact[damaged] * w[damaged]).sum() / max(w[damaged].sum(), 1e-12)),
                "glassExact": float((((out[:, LEVELS] > 0) == (y[:, 1] > 0.5)) * wn).sum())}, len(x)
    p = sigmoid(out)
    within = np.abs(p - y) <= 0.1
    return {k: float((within[:, j] * wn).sum()) for j, k in enumerate(
        ["someBroken", "blownOut", "fractionBroken", "thrownPast3b", "openingsBlownOut"]
        if unit == "side" else ["wallsModerate", "wallsHeavy", "roofModerate"])}, len(x)


def judge(args):
    models = dict(m.split("=", 1) for m in args.model)
    sets = {}
    for s in args.set:
        name, spec = s.split("=", 1)
        held = None
        if spec.endswith("@held"):
            spec, held = spec[:-5], True
        folders = []
        for part in spec.split(","):
            folders += [Path(p) for p in sorted(map(str, Path(part).parent.glob(Path(part).name)))
                        if (Path(p) / "meta.json").exists()]
        sets[name] = (folders, held)
    nets = {m: read_bclr(p) for m, p in models.items()}
    result = {}
    shown = [("component", "levelExactWhereDamaged", "Component level, damaged rows"),
             ("component", "glassExact", "Component glass"),
             ("side", "someBroken", "Glass some broken"), ("side", "blownOut", "Glass blown out"),
             ("building", "wallsModerate", "Walls moderate+"), ("building", "wallsHeavy", "Walls heavy+"),
             ("building", "roofModerate", "Roof moderate+")]
    for name, (folders, held) in sets.items():
        result[name] = {}
        for m, net in nets.items():
            result[name][m] = {}
            for unit in UNITS:
                totals, n = {}, 0
                for f in folders:
                    r, k = measures(unit, net, f, held)
                    if r is None:
                        continue
                    for key, v in r.items():
                        totals[key] = totals.get(key, 0) + v * k
                    n += k
                result[name][m][unit] = {k: v / n for k, v in totals.items()} if n else None
    print("| Scene | Measure (within 0.1 of the CPU's, or exact) | " + " | ".join(models) + " |")
    print("|---|---|" + "---|" * len(models))
    for name in sets:
        for unit, key, label in shown:
            vals = [result[name][m][unit][key] if result[name][m][unit] else None for m in models]
            if all(v is None for v in vals):
                continue
            print("| %s | %s | %s |" % (name, label, " | ".join("%.1f%%" % (100 * v) if v is not None else "–" for v in vals)))
    if args.out:
        Path(args.out).write_text(json.dumps(result, indent=1))


def audit(args):
    """For each labelled candidate, the first member's error on its labels against what the selection
    scored it: does the score find the error? Spearman's rank correlation over the candidates."""
    root = Path(args.dir)
    selection = json.loads((root / ("selection%s.json" % args.tag)).read_text())
    net = read_bclr(args.members.split(",")[0])
    rows_ = []
    for c, r in selection["candidates"].items():
        folder = root / "labels" / c
        if not (folder / "meta.json").exists():
            continue
        b, _ = measures("building", net, folder, None)
        s, _ = measures("side", net, folder, None)
        k, _ = measures("component", net, folder, None)
        error = np.mean([1 - b["wallsModerate"], 1 - b["wallsHeavy"], 1 - b["roofModerate"], 1 - s["blownOut"],
                         1 - k["levelExactWhereDamaged"]])
        rows_.append((c, error, r["value"], np.mean([r["units"][u]["novelty"] for u in r["units"]]),
                      np.mean([r["units"][u]["scatter"] for u in r["units"]])))

    def rank(v):
        return np.argsort(np.argsort(v))
    e = np.array([r[1] for r in rows_])
    print("| Candidate | Error on its labels | Value | Novelty | Scatter |\n|---|---|---|---|---|")
    for r in sorted(rows_, key=lambda r: -r[1]):
        print("| %s | %.3f | %.1f | %.2f | %.2f |" % r)
    for j, name in ((2, "value"), (3, "novelty"), (4, "scatter")):
        v = np.array([r[j] for r in rows_])
        rho = np.corrcoef(rank(e), rank(v))[0, 1] if len(rows_) > 2 else float("nan")
        print("Spearman, the error against the %s: %.2f over %d candidates" % (name, rho, len(rows_)))


# MARK: - The ranges the built-in scenes are checked against


def ranges(args):
    """Each network's inputs' 0.1% and 99.9% points over the training's rows (a weighted sample of
    them), and their names, as a Swift file built into BlastModel (`LiveResponse.TrainingRanges`):
    the live drag leaves to the CPU's preview a building whose inputs lie outside them, and
    `LiveResponseRangeTests` checks the built-in scenes against the same file. Written for the
    weights whose SHA-256 it names; run again whenever the built-in weights change."""
    import hashlib
    rng = np.random.default_rng(1)
    digest = hashlib.sha256(Path(args.weights).read_bytes()).hexdigest()
    folders = base_folders(args.base)
    # The glass thrown's network (emmettl/bombcad-work#117) reads the glass network's inputs, trained
    # on data of its own (`response-data --thrown-only`), and is built in as a file of its own.
    units = [(u, folders) for u in args.units.split(",")]
    if args.thrown:
        units.append(("thrown", base_folders(args.thrown)))
    thrown_digest = (hashlib.sha256(Path(args.thrown_weights).read_bytes()).hexdigest()
                     if args.thrown_weights else None)
    nets = []
    for unit, folders_ in units:
        xs, ws = [], []
        for f in folders_:
            x, _, w, _ = rows(f, unit)
            if len(x):
                xs.append(x)
                ws.append(w)
        x = np.concatenate(xs)
        w = np.concatenate(ws)
        pick = rng.choice(len(x), size=min(args.sample, len(x)), replace=False, p=w / w.sum())
        low = np.quantile(x[pick], 0.001, axis=0)
        high = np.quantile(x[pick], 0.999, axis=0)
        nets.append((unit, feature_names(unit, x.shape[1]), low, high))
        print("%s: %d rows of %d, %d inputs" % (unit, len(pick), len(x), x.shape[1]), flush=True)
    sources = sorted({f.parent.parent.name + "/" + f.parent.name for _, fs in units for f in fs})
    Path(args.out).write_text(ranges_swift(digest, thrown_digest, sources, nets))
    print("wrote %s for weights %s" % (args.out, digest[:12]))


def ranges_swift(digest, thrown_digest, sources, nets):
    """The ranges' Swift file (`LiveResponse+Ranges.swift`): `nets` each network's (name, input
    names, low points, high points)."""
    lines = ["// The live response's training ranges: each input's 0.1% and 99.9% points over the rows",
             "// the built-in weights were trained on (emmettl/bombcad-work#118). Written by",
             "// `Scripts/ml/corpus.py ranges` from %s;" % ", ".join(sources),
             "// run it again whenever the built-in weights change. The live drag leaves to the CPU's preview",
             "// what lies outside them (`LiveResponse.TrainingRanges`), and LiveResponseRangeTests checks the",
             "// built-in scenes against them.",
             "// swift-format-ignore-file",
             "",
             "extension LiveResponse.TrainingRanges {",
             "    /// The built-in weights' ranges (`forBuiltInWeights`).",
             "    public static let builtIn = LiveResponse.TrainingRanges(",
             '        weightsSHA256: "%s",' % digest,
             "        thrownSHA256: %s," % ('"%s"' % thrown_digest if thrown_digest else "nil"),
             "        networks: ["]

    def wrapped(items, indent):
        out, line = [], " " * indent
        for n, item in enumerate(items):
            piece = item + ("," if n < len(items) - 1 else "")
            if len(line) + len(piece) + 1 > 110 and line.strip():
                out.append(line.rstrip())
                line = " " * indent
            line += piece + " "
        out.append(line.rstrip())
        return out
    for unit, names, low, high in nets:
        lines += ['            "%s": Network(' % unit, "                names: ["]
        lines += wrapped(['"%s"' % n for n in names], 20)
        lines += ["                ],", "                low: ["]
        lines += wrapped(["%.6g" % t for t in low], 20)
        lines += ["                ],", "                high: ["]
        lines += wrapped(["%.6g" % t for t in high], 20)
        lines += ["                ]", "            ),"]
    lines += ["        ])", "}", ""]
    return "\n".join(lines)


# MARK: - What each model needs


NEEDS = {
    "field model (field model 2, the U-Net family)": {
        "from": "a solver run: scenebench field-export, or district-compare --export-field",
        "needs": ["peak overpressure and positive impulse on the plan, 2 m over the ground",
                  "the same at more heights (--levels 6,10,…) for the levels networks",
                  "the first phase's impulse (--first-phase)", "arrival (--arrival), roofs (--roof)",
                  "the plan's inputs: tallest block, ground, distance, ln Z, Kingery-Bulmash's peak and impulse"],
        "cost": "0.5-3.5 GPU min a run on 4 m cells (field-runs.py estimate)",
    },
    "live wave refinement (live-wave-unet-1)": {
        "from": "the same solver runs: blastmodel live-wave-features on a field export with --arrival",
        "needs": ["peak, arrival and positive impulse on the plan (the run's over the live wave's)",
                  "the live wave's own fields and sight on the 4 m plan and coarsened twice"],
        "cost": "nothing more than the field runs'",
    },
    "live response (the live drag's three networks)": {
        "from": "CPU only: scenebench response-data (no solver run)",
        "needs": ["each component's load (peak, impulse, rise) and shape, its construction",
                  "each glazed side's strips and the draws' spreads; each building's walls and roof",
                  "the answers: EnvelopeDamageAssessment, glassProbabilities, structureProbabilities"],
        "cost": "0.1-2 CPU min a frame (2 m squares to 4 m districts over 1.1 km); this tool's pool",
        "fromRuns": "a solver run's façade loads (district-compare --save-loads) would let the inputs be "
                    "the run's loads, not the surrogate's: building responses from runs",
    },
    "charge from damage": {
        "from": "CPU only: blastmodel charge-from-damage table (the quick estimate's chances on a grid)",
        "needs": ["each chosen building's chances of glass broken and walls moderate or heavy, by place and yield"],
        "cost": "minutes a table",
    },
}


def needs(args):
    print(json.dumps(NEEDS, indent=1))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pool")
    p.add_argument("dir")
    p.add_argument("--seeds", type=int, default=2)
    p.add_argument("--configs", default=POOL_CONFIGS, help="the kinds of run, comma-separated (CONFIGS)")
    p.add_argument("--first-seed", type=int, default=31)
    p.add_argument("--explorer", nargs=2, action="append", metavar=("NAME", "DX"),
                   help="the explorer's scene on cells of DX m, held out: probed and judged, never taken")
    p.add_argument("--probe-frames", type=int, default=8)
    p.add_argument("--label-frames", type=int, default=30)
    p.add_argument("--scene", nargs=2, action="append", metavar=("NAME", "OSM"),
                   help="a held-out scene on 2 m cells about (0, 0), as the explorer's: probed and judged, never taken")
    p = sub.add_parser("probe")
    p.add_argument("dir")
    p.add_argument("--jobs", type=int, default=3)
    for name in ("select", "check"):
        p = sub.add_parser(name)
        p.add_argument("dir")
        p.add_argument("--base", required=True, help="the training's data folders (or a folder of them), comma-separated")
        p.add_argument("--members", required=True, help="the ensemble's float32 .bclr files, the model itself first")
        p.add_argument("--sample", type=int, default=40000)
        if name == "select":
            p.add_argument("--budget", type=float, required=True, help="CPU hours for the round")
            p.add_argument("--tag", default="", help="written as active<tag>.json, fixed<tag>.json, selection<tag>.json")
            p.add_argument("--fixed-seed", type=int, default=7)
        else:
            p.add_argument("--also", help="more probe folders' names to score")
            p.add_argument("--out")
    p = sub.add_parser("round")
    p.add_argument("dir")
    p.add_argument("--list", help="lists to label, comma-separated (active, fixed)")
    p.add_argument("--scenes", action="store_true", help="label the held-out scenes, for judging")
    p.add_argument("--scene-frames", type=int, default=40)
    p.add_argument("--all", action="store_true", help="label every candidate (to audit the scores against)")
    p.add_argument("--jobs", type=int, default=3)
    p = sub.add_parser("pack")
    p.add_argument("dir")
    p.add_argument("--base-pack", required=True)
    p.add_argument("--out", required=True)
    p = sub.add_parser("judge")
    p.add_argument("--model", action="append", required=True, help="name=file.bclr")
    p.add_argument("--set", action="append", required=True, help="name=folder[,folder…][@held] (globs allowed)")
    p.add_argument("--out")
    p = sub.add_parser("audit")
    p.add_argument("dir")
    p.add_argument("--tag", default="")
    p.add_argument("--members", required=True)
    sub.add_parser("needs")
    p = sub.add_parser("ranges")
    p.add_argument("--base", required=True, help="the built-in weights' training folders, comma-separated")
    p.add_argument("--weights", required=True, help="the built-in weights (.bclr), whose SHA-256 the file names")
    p.add_argument("--units", default="component,side,building")
    p.add_argument("--thrown", help="the thrown network's training folders, comma-separated")
    p.add_argument("--thrown-weights", help="the thrown network's built-in weights (.bclr)")
    p.add_argument("--sample", type=int, default=400000)
    p.add_argument("--out", default=str(REPO / "Sources" / "BlastModel" / "LiveResponse+Ranges.swift"))
    args = parser.parse_args(argv)
    {"pool": pool, "probe": probe, "select": select, "check": check, "round": round_, "pack": pack,
     "judge": judge, "audit": audit, "needs": needs, "ranges": ranges}[args.command](args)


if __name__ == "__main__":
    main()
