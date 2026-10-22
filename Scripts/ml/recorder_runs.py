#!/usr/bin/env python3
"""The recorder's truth for judge_field.py: `district-compare --save-loads --export-field
--first-phase` runs of the dataset's held-out districts, at each dataset run's own top and length,
so that their fields are the dataset's to the bit and their strips are the recorder's.

    python3 -I Scripts/ml/recorder_runs.py --like /Volumes/StudioData/bombcad/ml/judge/compare-first \
        --out /Volumes/StudioData/bombcad/ml/judge/compare-fixed [--scenebench path] [--only id,id] [--dry-run]

Each run of `--like` (a folder of such runs, <id>/field/meta.json holding their arguments) is run
again with the same arguments into `--out`, under gpu-slot with its memory declared, one after
another; those already done are skipped. emmettl/bombcad-work#69 reran `compare-first` this way
after the terrain mapped-start fix (aff21dff).
"""
import argparse
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
GPU_SLOT = os.path.expanduser("~/.local/bin/gpu-slot")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--like", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--scenebench", default=os.path.join(REPOSITORY, ".build", "release", "scenebench"))
    parser.add_argument("--only")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    wanted = set(args.only.split(",")) if args.only else None
    failures = 0
    for run_id in sorted(os.listdir(args.like)):
        meta_path = os.path.join(args.like, run_id, "field", "meta.json")
        if not os.path.exists(meta_path) or (wanted and run_id not in wanted):
            continue
        target = os.path.join(args.out, run_id)
        if os.path.exists(os.path.join(target, "field", "meta.json")) and os.path.exists(
                os.path.join(target, "loads", "components.json")):
            print("%s: done" % run_id, flush=True)
            continue
        with open(meta_path) as handle:
            meta = json.load(handle)
        old = os.path.join(args.like, run_id)
        arguments = [a.replace(old, target) for a in meta["arguments"]]
        # The solver's memory, and the recorder's histories (2 GB by default) and room to spare.
        memory = int(math.ceil(meta["solverBytes"] * 1.2 / 1e9 + 4))
        command = [GPU_SLOT, "--mem", str(memory), os.path.abspath(args.scenebench), "district-compare"] + arguments
        print("%s: %s" % (run_id, " ".join(command)), flush=True)
        if args.dry_run:
            continue
        os.makedirs(target, exist_ok=True)
        with open(target + ".log", "w") as log:
            code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                  timeout=5400).returncode
        print("  exit %d" % code, flush=True)
        failures += code != 0
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
