#!/usr/bin/env python3
"""The field runs on another Mac: what field-runs.py run --on HOST sends through remote-train.py.

    python3 field_job.py --data STAGE --out OUT

STAGE holds bin/scenebench with its bundles, inputs/ and cases.json ({id, arguments}, paths
relative to STAGE, "OUT" for the run's folder). Each case runs in turn into OUT/runs/<id>, its
output in OUT/logs/<id>.txt; a case whose folder already holds a stable run is skipped.
"""
import argparse
import json
import os
import subprocess
import sys
import time


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    a = parser.parse_args(argv)
    with open(os.path.join(a.data, "cases.json")) as handle:
        cases = json.load(handle)
    scenebench = os.path.join(a.data, "bin", "scenebench")
    os.makedirs(os.path.join(a.out, "runs"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "logs"), exist_ok=True)
    failures = 0
    for case in cases:
        out = os.path.join(a.out, "runs", case["id"])
        try:
            with open(os.path.join(out, "meta.json")) as handle:
                if json.load(handle).get("stable"):
                    continue
        except (OSError, ValueError):
            pass
        arguments = [out if argument == "OUT" else argument for argument in case["arguments"]]
        started = time.time()
        with open(os.path.join(a.out, "logs", case["id"] + ".txt"), "w") as log:
            code = subprocess.run([scenebench] + arguments, cwd=a.data, stdout=log, stderr=subprocess.STDOUT).returncode
        print("%s: exit %d after %.0f s" % (case["id"], code, time.time() - started), flush=True)
        failures += code != 0
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
