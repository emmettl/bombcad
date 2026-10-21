#!/usr/bin/env python3
"""Judge the app's quick estimate with the learned field model on (emmettl/bombcad-work#67).

    python app_peaks.py run --data DATASET --weights field.bcfw --out-dir FOLDER [--split split.json]
        [--match beirut] [--scenebench .build/release/scenebench] [--gpu-slot ~/.local/bin/gpu-slot]
    python app_peaks.py merge --app FOLDER --peaks FOLDER --out-dir FOLDER
    python app_peaks.py glass --peaks FOLDER --recorded FOLDER --out-dir FOLDER [--variants strict,app]
    python app_peaks.py summary --glass FOLDER --data DATASET

`run` lays out each held-out run's district again (its `field-export` arguments from the dataset's
meta.json) and runs `scenebench field-app` on it: the app's own estimate path
(`FacadeLoadSurrogate.Prepared.estimate` with `LearnedField.Estimator`, the network on the GPU under
gpu-slot), writing each façade strip's surrogate and in-app peaks to FOLDER/<id>.csv, with the
network's inputs checked against the run's `inputs.npy` to the bit.

`merge` adds the in-app peak (`peak:app`, `impulse:app`, the surrogate's impulse) to each run's
`judge_field.py --peaks-out` file, on the same strips, so that `scenebench field-glass` and
`judge_field.py walls` judge the in-app peaks exactly as they judged the Python model's
(docs/learned-models.md). A judged strip the app gave no model peak to keeps the surrogate's, as
the app does.

`glass` runs `scenebench field-glass` on each merged run (CPU only), and `summary` sums them over
runs: exact, within one, Heidke's skill and the mean error of the share broken, overall, by
distance and by yield. The walls go through `judge_field.py walls --peaks MERGED
--variants surrogate,strict:surrogate,app:surrogate`.
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
YIELDS = [(0, 0.1), (0.1, 0.3), (0.3, 0.7), (0.7, 2.1)]


def key(row):
    return (int(row["axis"]), int(row["outward"])) + tuple(int(round(10 * float(row[c])))
                                                           for c in ("x0", "y0", "z0", "x1", "y1", "z1"))


def run_main(args):
    with open(args.split) as handle:
        held = [r for r in json.load(handle)["heldOut"] if r.startswith(args.match)]
    os.makedirs(args.out_dir, exist_ok=True)
    for run_id in held:
        target = os.path.join(args.out_dir, run_id + ".csv")
        if os.path.exists(target):
            continue
        folder = os.path.join(args.data, "runs", run_id)
        with open(os.path.join(folder, "meta.json")) as handle:
            arguments = json.load(handle)["arguments"]
        i = arguments.index("--out")
        del arguments[i:i + 2]
        arguments = [a for a in arguments if a != "--first-phase"]
        command = [args.gpu_slot, "--mem", "6", args.scenebench, "field-app"] + arguments + [
            "--weights", args.weights, "--check-inputs", folder, "--out", target + ".tmp"]
        began = time.time()
        with open(os.path.join(args.out_dir, run_id + ".log"), "w") as log:
            code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
        if code != 0:
            print("app_peaks: %s exit %d" % (run_id, code))
            continue
        os.replace(target + ".tmp", target)
        print("app_peaks: %s, %.0f s" % (run_id, time.time() - began))
        sys.stdout.flush()
    return 0


def merge_main(args):
    os.makedirs(args.out_dir, exist_ok=True)
    totals = {"judged": 0, "learned": 0, "missing": 0}
    for name in sorted(os.listdir(args.app)):
        if not name.endswith(".csv") or not os.path.exists(os.path.join(args.peaks, name)):
            continue
        with open(os.path.join(args.app, name)) as handle:
            app = {key(r): r for r in csv.DictReader(handle)}
        with open(os.path.join(args.peaks, name)) as handle:
            reader = csv.DictReader(handle)
            fields = reader.fieldnames + ["peak:app", "impulse:app"]
            rows = list(reader)
        counts = {"judged": 0, "learned": 0, "missing": 0}
        with open(os.path.join(args.out_dir, name), "w") as handle:
            handle.write(",".join(fields) + "\n")
            for row in rows:
                found = app.get(key(row))
                counts["judged"] += 1
                if found is None:
                    # Not among the app's façade strips: judged on the surrogate (as field-glass
                    # does for a peak it is not given, it would not find the strip either).
                    counts["missing"] += 1
                    continue
                counts["learned"] += found["learned"] == "1"
                row["peak:app"] = found["peak:app"]
                row["impulse:app"] = found["impulse:surrogate"]
                handle.write(",".join(row[f] for f in fields) + "\n")
        for k in totals:
            totals[k] += counts[k]
        print("app_peaks merge: %s, %d judged strips, %d with the model's peak in the app, %d not found" % (
            name[:-4], counts["judged"], counts["learned"], counts["missing"]))
    print("app_peaks merge: %d judged strips, %d (%.3f) with the model's peak in the app, %d not found" % (
        totals["judged"], totals["learned"], totals["learned"] / max(totals["judged"], 1), totals["missing"]))
    return 0


def glass_main(args):
    os.makedirs(args.out_dir, exist_ok=True)
    for name in sorted(os.listdir(args.peaks)):
        if not name.endswith(".csv"):
            continue
        run_id = name[:-4]
        target = os.path.join(args.out_dir, run_id + ".json")
        meta = os.path.join(args.recorded, run_id, "field", "meta.json")
        if os.path.exists(target) or not os.path.exists(meta):
            continue
        with open(meta) as handle:
            arguments = json.load(handle)["arguments"]
        if "--out" in arguments:
            i = arguments.index("--out")
            del arguments[i:i + 2]
        # Only the asked variants' peaks: a copy of the file with their columns.
        with open(os.path.join(args.peaks, name)) as handle:
            reader = csv.DictReader(handle)
            keep = reader.fieldnames[:8] + [f for f in reader.fieldnames[8:]
                                            if f.split(":", 1)[1] in args.variants.split(",")]
            rows = list(reader)
        trimmed = os.path.join(args.out_dir, name)
        with open(trimmed, "w") as handle:
            handle.write(",".join(keep) + "\n")
            for row in rows:
                handle.write(",".join(row[f] for f in keep) + "\n")
        command = [args.scenebench, "field-glass"] + arguments + [
            "--loads", os.path.join(args.recorded, run_id, "loads"), "--peaks", trimmed, "--out", target + ".tmp"]
        began = time.time()
        with open(os.path.join(args.out_dir, run_id + ".log"), "w") as log:
            code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
        if code != 0:
            print("app_peaks glass: %s exit %d" % (run_id, code))
            continue
        os.replace(target + ".tmp", target)
        print("app_peaks glass: %s, %.0f s" % (run_id, time.time() - began))
        sys.stdout.flush()
    return 0


def heidke(c):
    n = sum(map(sum, c))
    po = sum(c[i][i] for i in range(3)) / n
    pe = sum(sum(c[i]) * sum(r[i] for r in c) for i in range(3)) / n / n
    return (po - pe) / (1 - pe) if pe < 1 else float("nan")


def summary_main(args):
    totals, errors, sides = {}, {}, {}
    count = 0
    for name in sorted(os.listdir(args.glass)):
        if not name.endswith(".json"):
            continue
        run_id = name[:-5]
        with open(os.path.join(args.glass, name)) as handle:
            judged = json.load(handle)
        with open(os.path.join(args.data, "runs", run_id, "meta.json")) as handle:
            kt = json.load(handle)["charge"]["yieldKt"]
        count += 1
        band = next("yield %.1f-%.1f kt" % (lo, hi) for lo, hi in YIELDS if lo <= kt < hi)
        for group, row in judged["groups"].items():
            for g in [group] + ([band] if group == "all" else []):
                for p, a in row.items():
                    c = totals.setdefault(g, {}).setdefault(p, [[0] * 3 for _ in range(3)])
                    for r in range(3):
                        for s in range(3):
                            c[r][s] += a["confusion"][r][s]
                    errors.setdefault(g, {}).setdefault(p, 0.0)
                    errors[g][p] += judged["fractionError"][group][p]
                sides[g] = sides.get(g, 0) + judged["bandSides"][group]
    order = ["all"] + sorted([g for g in totals if g.endswith(" m") and not g.startswith(">")],
                             key=lambda g: float(g.split("-")[0])) + sorted(g for g in totals if g.startswith(">")) + \
        sorted(g for g in totals if g.startswith("yield"))
    predictors = sorted(next(iter(totals.values())).keys())
    print("%d runs; each cell exact / Heidke skill / mean |share broken error|" % count)
    print("group | sides | " + " | ".join(predictors))
    for g in order:
        cells = []
        for p in predictors:
            c = totals[g][p]
            n = sum(map(sum, c))
            exact = sum(c[i][i] for i in range(3)) / n
            cells.append("%.3f / %.2f / %.3f" % (exact, heidke(c), errors[g][p] / max(sides[g], 1)))
        print("%s | %d | %s" % (g, sides[g], " | ".join(cells)))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--data", required=True)
    r.add_argument("--weights", required=True)
    r.add_argument("--out-dir", required=True)
    r.add_argument("--split", default="/Volumes/StudioData/bombcad/ml/field-unet-fp-strict/out/split.json")
    r.add_argument("--match", default="beirut")
    r.add_argument("--scenebench", default=os.path.join(REPOSITORY, ".build", "release", "scenebench"))
    r.add_argument("--gpu-slot", default=os.path.expanduser("~/.local/bin/gpu-slot"))
    m = sub.add_parser("merge")
    m.add_argument("--app", required=True)
    m.add_argument("--peaks", required=True)
    m.add_argument("--out-dir", required=True)
    g = sub.add_parser("glass")
    g.add_argument("--peaks", required=True)
    g.add_argument("--recorded", default="/Volumes/StudioData/bombcad/ml/judge/compare-first")
    g.add_argument("--out-dir", required=True)
    g.add_argument("--variants", default="strict,app")
    g.add_argument("--scenebench", default=os.path.join(REPOSITORY, ".build", "release", "scenebench"))
    s = sub.add_parser("summary")
    s.add_argument("--glass", required=True)
    s.add_argument("--data", default="/Volumes/StudioData/bombcad/ml/datasets/main-fp")
    args = parser.parse_args(argv)
    return {"run": run_main, "merge": merge_main, "glass": glass_main, "summary": summary_main}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
