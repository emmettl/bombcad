#!/usr/bin/env python3
"""The learned field model's training runs: plan the list, estimate it, and run it.

    python3 -I Scripts/ml/field-runs.py plan       # (re)write Scripts/ml/field-runs.json
    python3 -I Scripts/ml/field-runs.py estimate [--set main]
    python3 -I Scripts/ml/field-runs.py run --set smoke --dataset /Volumes/StudioData/bombcad/ml/datasets/smoke
        [--only id,id] [--limit N] [--scenebench .build/release/scenebench] [--on scrimply-ci-tb] [--dry-run]

Each run is one `scenebench field-export` (docs/learned-models.md): a district laid out about a
charge on the ground, the air run on 4 m cells until the blast has passed the corners, and its
peak overpressure and impulse 2 m over the ground written with the plan's inputs as .npy files.
The made-up districts are drawn by make_district.py into /Volumes/StudioData/bombcad/ml/layouts;
Beirut's inputs are read where the Beirut page's runs read them.

`run` puts each case under gpu-slot here, declaring its memory, one after another, skipping those
already in the dataset (so a stopped list carries on), and keeps each to 1.5 hours. With `--on
HOST` the cases go to that host instead through remote-train.py: scenebench, its bundles and the
cases' inputs are sent as one dataset (sent once, by its content) and field_job.py runs them
there under the host's lock; their folders come back into the dataset.
"""
import argparse
import json
import math
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
LIST = os.path.join(HERE, "field-runs.json")
ML = "/Volumes/StudioData/bombcad/ml"
LAYOUTS = os.path.join(ML, "layouts")
BEIRUT = "/Volumes/StudioData/bombcad/data/Beirut2020"
GPU_SLOT = os.path.expanduser("~/.local/bin/gpu-slot")
# Beirut's inputs as the Beirut page's runs read them (beirut/scene/inputs-base.sh), the charge at the port.
BEIRUT_INPUTS = {
    "osm": BEIRUT + "/OSM/beirut-port-buildings.osm",
    "dem": BEIRUT + "/DEM/Copernicus_DSM_COG_10_N33_00_E035_00_DEM.tif",
    "heights": BEIRUT + "/GHSL/GHS_BUILT_H_ANBH_E2018_GLOBE_R2023A_4326_3ss_V1_0_R6_C22.tif",
    "extra": ["--ground-radius", "100", "--sea", "1"],
    "centre": [35.519042, 33.901425],
}
M = 6_371_008.8 * math.pi / 180  # metres per degree
DX = 4.0
MAX_SECONDS = 1.5 * 3600
# The cost of a run, fitted to the smoke runs on the Studio (see `fit` and docs/learned-models.md):
# wall seconds = nsPerCellStep * 1e-9 * cells * steps, steps = until * stepRate * 4 / dx, and the
# solver's memory bytesPerCell * cells.
COST = {"nsPerCellStep": 1.0, "stepsPerSecond": 600.0, "bytesPerCell": 73.0, "fixedS": 5.0, "beirutFixedS": 40.0,
        "beirutExtraGB": 1.0,
        "calibratedOn": "the six smoke runs on the Studio, 20 Oct 2026: 0.46-0.65 ns a cell-step quiet, 1.0-1.3 "
                        "with the cold start and other jobs; 573 steps a simulated second on 4 m cells; the "
                        "solver 73 bytes a cell; Beirut's 12,000 x 12,000 height grid takes 17-40 s to read"}


# MARK: - The plan

def top(mass, relief):
    """The domain's top, m, as DistrictLayout.top makes it: 4 m/kg^(1/3) over the charge, at least
    half of it over the roofs (taken as the terrain's relief), to whole cells."""
    clearance = 4 * mass ** (1 / 3)
    return math.ceil(max(clearance, relief + clearance / 2) / DX) * DX


def until(radius, mass):
    """FieldExport.duration's run length, roughly: Kingery–Bulmash's arrival at the corners plus the
    positive phase, from a sound-speed fit (scenebench computes it exactly)."""
    root = mass ** (1 / 3)
    corner = radius * math.sqrt(2)
    lz = math.log(min(corner / root, 40))
    # Arrival and positive duration per kg^(1/3), s: quadratics in ln Z fitted to Kingery–Bulmash
    # (Scripts/reference/kingery_bulmash.py) over Z 4 to 40, within 3%.
    arrival = root * math.exp(-0.11176 * lz * lz + 1.82011 * lz - 7.43767) + max(0.0, corner - 40 * root) / 343
    positive = root * math.exp(-0.03097 * lz * lz + 0.46939 * lz - 6.25605)
    return round((arrival + positive) * 1.1, 2)


def estimate(run, layouts, cost=COST):
    mass, radius = run["massKg"], run["radiusM"]
    layout = layouts[run["layout"]]
    relief = layout.get("reliefM", 0)
    cells = int((2 * radius / DX) ** 2 * top(mass, relief) / DX)
    seconds_run = until(radius, mass)
    steps = int(seconds_run * cost["stepsPerSecond"] * 4 / DX)
    beirut = layout["kind"] == "beirut"
    seconds = cost["fixedS"] + (cost["beirutFixedS"] if beirut else 0) + cost["nsPerCellStep"] * 1e-9 * cells * steps
    memory = cost["bytesPerCell"] * cells * 1.5 + (cost["beirutExtraGB"] * 1e9 if beirut else 0)
    return {"cells": cells, "untilS": seconds_run, "steps": steps, "seconds": round(seconds),
            "memGB": max(2, int(math.ceil(memory / 1e9)))}


def plan(seed=2026):
    """The run list: made-up districts of five styles over terrains, and Beirut with the charge at
    the port and elsewhere in the city, over yields 0.05 to 2 kt, log-uniform in strata."""
    rng = random.Random(seed)
    layouts = {}
    runs = []
    styles = ["perimeter", "grid", "towers", "industrial", "mixed"]
    terrains = ["flat", "flat", "slope", "hill", "valley", "flat"]
    reliefs = {"flat": 0, "slope": 70, "hill": 60, "valley": 60}
    per_layout = 5
    for style in styles:
        for seed_n, terrain in enumerate(terrains, 1):
            name = "made-%s-s%d" % (style, seed_n)
            layouts[name] = {"kind": "made-up", "style": style, "seed": seed_n, "terrain": terrain,
                             "extentM": 2600, "reliefM": reliefs[terrain]}
            # One yield from each fifth of the log range, in a shuffled order.
            strata = list(range(per_layout))
            rng.shuffle(strata)
            for n, stratum in enumerate(strata):
                kt = math.exp(math.log(0.05) + (stratum + rng.random()) / per_layout * math.log(2 / 0.05))
                runs.append({
                    "id": "%s-%d" % (name, n + 1), "layout": name,
                    "offsetM": [round(rng.uniform(-150, 150)), round(rng.uniform(-150, 150))],
                    "massKg": int(round(kt * 1e6, -2)), "radiusM": 1024 if kt < 0.5 else 1280,
                })
    layouts["beirut"] = {"kind": "beirut", "reliefM": 100,
                         "note": "OSM buildings, Copernicus DEM and GHSL heights, as docs/beirut-2020.md"}
    # The port, then points in the city south, east and west of it (the north is the sea).
    places = [(0, 0), (-600, -400), (600, -500), (0, -900), (-1200, -700), (1200, -900), (-300, -1500),
              (500, -1500), (-1500, -1200), (1500, -300)]
    for p, (east, north) in enumerate(places):
        strata = list(range(5))
        rng.shuffle(strata)
        for n, stratum in enumerate(strata):
            kt = math.exp(math.log(0.05) + (stratum + rng.random()) / 5 * math.log(2 / 0.05))
            runs.append({"id": "beirut-p%d-%d" % (p, n + 1), "layout": "beirut", "offsetM": [east, north],
                         "massKg": int(round(kt * 1e6, -2)), "radiusM": 1024 if kt < 0.5 else 1280})
    smoke = [
        {"id": "smoke-perimeter-50t", "layout": "made-perimeter-s1", "offsetM": [0, 0], "massKg": 50000},
        {"id": "smoke-grid-30t", "layout": "made-grid-s3", "offsetM": [40, -60], "massKg": 30000},
        {"id": "smoke-towers-80t", "layout": "made-towers-s4", "offsetM": [-30, 20], "massKg": 80000},
        {"id": "smoke-industrial-20t", "layout": "made-industrial-s2", "offsetM": [60, 60], "massKg": 20000},
        {"id": "smoke-mixed-100t", "layout": "made-mixed-s5", "offsetM": [-50, -40], "massKg": 100000},
        {"id": "smoke-beirut-50t", "layout": "beirut", "offsetM": [0, -900], "massKg": 50000},
    ]
    for run in smoke:
        run["radiusM"] = 512
    return {"layouts": layouts, "sets": {"main": runs, "smoke": smoke}}


def with_estimates(data, cost=COST):
    for runs in data["sets"].values():
        for run in runs:
            run["estimate"] = estimate(run, data["layouts"], cost)
    totals = {}
    for name, runs in data["sets"].items():
        seconds = sum(run["estimate"]["seconds"] for run in runs)
        totals[name] = {"runs": len(runs), "gpuHours": round(seconds / 3600, 2),
                        "longestMinutes": round(max(run["estimate"]["seconds"] for run in runs) / 60, 1),
                        "largestMemGB": max(run["estimate"]["memGB"] for run in runs),
                        "datasetGB": round(sum(4 * 9 * (2 * run["radiusM"] / DX) ** 2 for run in runs) / 1e9, 2)}
    return dict({"format": "bombcad-field-runs-1",
                 "about": "Training runs for the learned field model (docs/learned-models.md); written by "
                          "Scripts/ml/field-runs.py plan. Estimates are for the Studio's M4 Max, one run at "
                          "a time; the CI mini takes about 3-4 times as long.",
                 "cellSizeM": DX, "heightAboveGroundM": 2, "costModel": cost, "totals": totals}, **data)


# MARK: - Running

def centre_of(run, layout):
    if layout["kind"] == "beirut":
        lon0, lat0 = BEIRUT_INPUTS["centre"]
    else:
        lon0 = lat0 = layout["extentM"] / 2 / M
    east, north = run["offsetM"]
    return lon0 + east / (M * math.cos(math.radians(lat0))), lat0 + north / M


def inputs_for(name, layout, make=True):
    """The scenebench inputs of a layout: {"osm", "dem", "heights", "extra"}, drawing a made-up one
    first if need be."""
    if layout["kind"] == "beirut":
        return BEIRUT_INPUTS
    folder = os.path.join(LAYOUTS, name)
    osm = os.path.join(folder, "district.osm")
    if make and not os.path.exists(osm):
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "make_district.py"), folder, "--style",
                        layout["style"], "--seed", str(layout["seed"]), "--extent", str(layout["extentM"]),
                        "--terrain", layout["terrain"]], check=True, stdout=subprocess.DEVNULL)
    dem = os.path.join(folder, "ground.asc")
    return {"osm": osm, "dem": dem if layout["terrain"] != "flat" else None, "heights": None, "extra": []}


def field_arguments(run, layout, inputs, out, relative=None):
    """scenebench field-export's arguments for `run`; paths made relative to `relative` if given."""
    def path(p):
        return os.path.relpath(p, relative) if relative else p
    lon, lat = centre_of(run, layout)
    arguments = ["field-export", "--osm", path(inputs["osm"])]
    if inputs.get("dem"):
        arguments += ["--dem", path(inputs["dem"])]
    if inputs.get("heights"):
        arguments += ["--heights", path(inputs["heights"])]
    arguments += list(inputs.get("extra", [])) + [
        "--centre", "%.8f,%.8f" % (lon, lat), "--radius", str(run["radiusM"]), "--dx", str(int(DX)),
        "--mass", str(run["massKg"]), "--ground", "saturated", "--id", run["id"], "--layout", run["layout"],
        "--out", out]
    return arguments


def done(folder):
    try:
        with open(os.path.join(folder, "meta.json")) as handle:
            return json.load(handle).get("stable") is True
    except (OSError, ValueError):
        return False


def index(dataset):
    """dataset.json: the runs present, with their meta's essentials."""
    runs = []
    for name in sorted(os.listdir(os.path.join(dataset, "runs"))) if os.path.isdir(os.path.join(dataset, "runs")) else []:
        folder = os.path.join(dataset, "runs", name)
        if done(folder):
            with open(os.path.join(folder, "meta.json")) as handle:
                meta = json.load(handle)
            runs.append({key: meta.get(key) for key in ("id", "layout", "rows", "columns", "cellSizeM", "wallS",
                                                          "steps", "cells", "solverBytes", "untilS")}
                        | {"massKg": meta["charge"]["massKg"]})
    with open(os.path.join(dataset, "dataset.json"), "w") as handle:
        json.dump({"format": "bombcad-field-dataset-1", "runs": runs,
                   "about": "Training pairs for the learned field model: runs/<id>/{inputs,targets,mask}.npy "
                            "and meta.json (docs/learned-models.md)"}, handle, indent=1)
    return runs


def select(data, arguments):
    runs = data["sets"][arguments.set]
    if arguments.only:
        wanted = set(arguments.only.split(","))
        runs = [run for run in runs if run["id"] in wanted]
    if arguments.limit:
        runs = runs[:arguments.limit]
    return runs


def run_here(data, runs, arguments):
    scenebench = os.path.abspath(arguments.scenebench)
    revision = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPOSITORY, capture_output=True,
                              text=True).stdout.strip()
    os.makedirs(os.path.join(arguments.dataset, "runs"), exist_ok=True)
    os.makedirs(os.path.join(arguments.dataset, "logs"), exist_ok=True)
    failures = 0
    for run in runs:
        out = os.path.join(arguments.dataset, "runs", run["id"])
        if done(out):
            print("%s: already in the dataset" % run["id"], flush=True)
            continue
        layout = data["layouts"][run["layout"]]
        command = [GPU_SLOT, "--mem", str(run["estimate"]["memGB"]), scenebench] + \
            field_arguments(run, layout, inputs_for(run["layout"], layout, make=not arguments.dry_run), out)
        print("%s: %s" % (run["id"], " ".join(command)), flush=True)
        if arguments.dry_run:
            continue
        started = time.time()
        with open(os.path.join(arguments.dataset, "logs", run["id"] + ".txt"), "w") as log:
            try:
                code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=MAX_SECONDS,
                                      env=dict(os.environ, BOMBCAD_SOURCE_REVISION=revision)).returncode
            except subprocess.TimeoutExpired:
                code = 124
        print("%s: exit %d after %.0f s (estimated %d s)" % (run["id"], code, time.time() - started,
                                                            run["estimate"]["seconds"]), flush=True)
        failures += code != 0
    if not arguments.dry_run:
        print("%d runs in %s" % (len(index(arguments.dataset)), arguments.dataset))
    return 1 if failures else 0


def run_there(data, runs, arguments):
    """Sends scenebench, its bundles and the cases' inputs as one dataset to `--on`, runs them with
    field_job.py under remote-train.py, and moves the runs that come back into the dataset."""
    scenebench = os.path.abspath(arguments.scenebench)
    stage = os.path.join(ML, "staging", "fields-%s" % arguments.on)
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, "bin"))
    shutil.copy2(scenebench, os.path.join(stage, "bin", "scenebench"))
    for name in os.listdir(os.path.dirname(scenebench)):
        if name.endswith(".bundle"):
            shutil.copytree(os.path.join(os.path.dirname(scenebench), name), os.path.join(stage, "bin", name))
    cases = []
    for run in runs:
        if done(os.path.join(arguments.dataset, "runs", run["id"])):
            continue
        layout = data["layouts"][run["layout"]]
        inputs = dict(inputs_for(run["layout"], layout))
        for key in ("osm", "dem", "heights"):
            if inputs.get(key):
                target = os.path.join(stage, "inputs", run["layout"], os.path.basename(inputs[key]))
                if not os.path.exists(target):
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copy2(inputs[key], target)
                inputs[key] = target
        cases.append({"id": run["id"], "seconds": run["estimate"]["seconds"],
                      "arguments": field_arguments(run, layout, inputs, "OUT", relative=stage)})
    with open(os.path.join(stage, "cases.json"), "w") as handle:
        json.dump(cases, handle, indent=1)
    job = "fields-%s-%s" % (arguments.on.split(".")[0], time.strftime("%Y%m%d-%H%M%S", time.gmtime()))
    command = [sys.executable, "-I", os.path.join(HERE, "remote-train.py"), arguments.on, stage,
               os.path.join(HERE, "field_job.py"), "--venv", "none", "--job", job,
               "--timeout", str(int(min(MAX_SECONDS, 300 + 4 * sum(c["seconds"] for c in cases))))]
    if arguments.dry_run:
        command.append("--dry-run")
    print(" ".join(command), flush=True)
    result = subprocess.run(command, capture_output=False, text=True)
    if arguments.dry_run:
        return result.returncode
    back = os.path.join(ML, job, "out", "runs")
    os.makedirs(os.path.join(arguments.dataset, "runs"), exist_ok=True)
    for name in os.listdir(back) if os.path.isdir(back) else []:
        if done(os.path.join(back, name)):
            target = os.path.join(arguments.dataset, "runs", name)
            shutil.rmtree(target, ignore_errors=True)
            shutil.move(os.path.join(back, name), target)
    print("%d runs in %s" % (len(index(arguments.dataset)), arguments.dataset))
    return result.returncode


def fit(dataset):
    """The cost model's constants from a dataset's runs: ns per cell-step, steps per simulated
    second (at 4 m), solver bytes per cell."""
    runs = [run for run in index(dataset) if run.get("wallS") and run.get("steps")]
    ns = sorted(1e9 * run["wallS"] / (run["cells"] * run["steps"]) for run in runs)
    rate = sorted(run["steps"] / run["untilS"] for run in runs)
    per_cell = sorted(run["solverBytes"] / run["cells"] for run in runs if run.get("solverBytes"))
    middle = lambda values: values[len(values) // 2] if values else None
    return {"runs": len(runs), "nsPerCellStep": middle(ns), "nsPerCellStepRange": [ns[0], ns[-1]] if ns else None,
            "stepsPerSecond": middle(rate), "bytesPerCell": middle(per_cell)}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--out", default=LIST)
    p.add_argument("--cost", help="a JSON file of cost constants (from fit) to estimate with")
    e = sub.add_parser("estimate")
    e.add_argument("--list", default=LIST)
    e.add_argument("--set", default="main")
    f = sub.add_parser("fit")
    f.add_argument("dataset")
    r = sub.add_parser("run")
    r.add_argument("--list", default=LIST)
    r.add_argument("--set", default="smoke")
    r.add_argument("--dataset", required=True)
    r.add_argument("--only")
    r.add_argument("--limit", type=int)
    r.add_argument("--scenebench", default=os.path.join(REPOSITORY, ".build", "release", "scenebench"))
    r.add_argument("--on", help="an SSH host to run the cases on through remote-train.py")
    r.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args(argv)
    if arguments.command == "plan":
        cost = dict(COST)
        if arguments.cost:
            with open(arguments.cost) as handle:
                cost.update(json.load(handle))
        data = with_estimates(plan(), cost)
        with open(arguments.out, "w") as handle:
            json.dump(data, handle, indent=1)
            handle.write("\n")
        print(json.dumps(data["totals"], indent=1))
        return 0
    if arguments.command == "fit":
        print(json.dumps(fit(arguments.dataset), indent=1))
        return 0
    with open(arguments.list) as handle:
        data = json.load(handle)
    if arguments.command == "estimate":
        runs = data["sets"][arguments.set]
        seconds = [run["estimate"]["seconds"] for run in runs]
        print("%d runs, %.1f GPU hours on the Studio one at a time (%.1f to %.1f min each), memory up to %d GB" % (
            len(runs), sum(seconds) / 3600, min(seconds) / 60, max(seconds) / 60,
            max(run["estimate"]["memGB"] for run in runs)))
        return 0
    runs = select(data, arguments)
    if arguments.on:
        return run_there(data, runs, arguments)
    return run_here(data, runs, arguments)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
