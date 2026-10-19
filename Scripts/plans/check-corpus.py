#!/usr/bin/env python3
"""Checks the plan importer against its corpus (Fixtures/FloorPlans): builds scenebench and runs
`scenebench plan-check`, which reads each plan headlessly as its JSON asks and compares what it
finds with the answer expected. Exits as it does (1 if any plan differs).

    python3 Scripts/plans/check-corpus.py [folder]
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "Fixtures", "FloorPlans")
    subprocess.run(["swift", "build", "--product", "scenebench"], cwd=ROOT, check=True)
    binary = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True, capture_output=True,
                            text=True).stdout.strip()
    sys.exit(subprocess.run([os.path.join(binary, "scenebench"), "plan-check", folder], cwd=ROOT).returncode)


if __name__ == "__main__":
    main()
