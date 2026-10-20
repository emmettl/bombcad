#!/usr/bin/env python3
"""Runs the calibration's design (Scripts/calibration/design.json) for some cases on the shared CI
Mac, as `make check-remote` runs a check there (Scripts/remote.py: its lock, its waiting for the
runners and the quiet window), and appends each run's outputs to a JSON-lines file here
(docs/calibration.md).

    python3 Scripts/calibration/runs.py <case>[,<case>…] --out runs.jsonl [--here]

`--here` runs on this Mac instead (inside `gpu-slot` when there is one).
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
import remote  # noqa: E402

DESIGN = "Scripts/calibration/design.json"


def command(cases):
    return ["bash", "-c",
            "swift build -c release --product BombCAD >/dev/null && "
            ".build/release/BombCAD ensemble %s --design %s --no-default-workers" % (cases, DESIGN)]


def main(arguments):
    if not arguments or "--out" not in arguments:
        print(__doc__, file=sys.stderr)
        return 2
    cases = arguments[0]
    out = arguments[arguments.index("--out") + 1]
    if "--here" in arguments:
        wrapped = command(cases)
        if shutil.which("gpu-slot"):
            wrapped = ["gpu-slot", "--mem", "8"] + wrapped
        process = subprocess.Popen(wrapped, cwd=ROOT, stdout=subprocess.PIPE, text=True)
        lines = process.stdout
    else:
        settings = remote.config()
        host = os.environ.get("BOMBCAD_REMOTE_HOST") or settings["host"]
        # The remote's output comes through this process's standard output: read it back through a
        # pipe of our own.
        read, write = os.pipe()
        child = os.fork()
        if child == 0:
            os.close(read)
            os.dup2(write, 1)
            code = remote.check_remote(host, settings, "calibration", wait=7200, command=command(cases))
            sys.stdout.flush()
            os._exit(code)
        os.close(write)
        lines = os.fdopen(read, "r", errors="replace")
    with open(out, "a") as sink:
        for line in lines:
            sys.stdout.write(line)
            sys.stdout.flush()
            if line.startswith("MEASURED "):
                path = os.path.join(os.path.dirname(os.path.abspath(out)), "measured.json")
                known = json.load(open(path)) if os.path.exists(path) else {}
                known.update(json.loads(line[len("MEASURED "):]))
                with open(path, "w") as f:
                    json.dump(known, f, indent=1)
            if line.startswith("DESIGN "):
                sink.write(json.dumps(json.loads(line[len("DESIGN "):])) + "\n")
                sink.flush()
    if "--here" in arguments:
        return process.wait()
    return os.waitpid(child, 0)[1] >> 8


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
