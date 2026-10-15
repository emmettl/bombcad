"""Tests of concrete-matrix.py's rounding ensemble: python3 Scripts/test-concrete-matrix.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))

# A stand-in blastbench: Janney's table, its moment set by the --rounding it is given.
FAKE = """#!/bin/sh
moment=41.7
case "$*" in
  *"--rounding unfused"*) moment=42.0 ;;
  *"--rounding relaxed"*) moment=41.9 ;;
esac
echo "  layers  elements        peak  vs test  fails at       rms  failed  run time"
echo "      12      8640   $moment kN m     101%     44 mm  1.6 kN m      30    81.1 s"
"""


class RoundingEnsembleTests(unittest.TestCase):
    def test_each_row_gives_the_default_and_the_roundings_range(self):
        with tempfile.TemporaryDirectory() as folder:
            bench = os.path.join(folder, "blastbench")
            with open(bench, "w") as f:
                f.write(FAKE)
            os.chmod(bench, 0o755)
            out = os.path.join(folder, "out")
            subprocess.run(
                [sys.executable, os.path.join(here, "concrete-matrix.py"), "--quick", "--cases", "janney",
                 "--rounding-ensemble", "--blastbench", bench, "--out", out],
                check=True, capture_output=True, text=True)
            report = json.load(open(os.path.join(out, "matrix.json")))
            row = report["cases"][0]["rows"][0]
            self.assertEqual(row["model"], 41.7)
            self.assertEqual(row["roundings"], {"default": 41.7, "unfused": 42.0, "relaxed": 41.9})
            table = open(os.path.join(out, "matrix.md")).read()
            self.assertIn("41.7 kN m (41.7–42)", table)
            for name in ("janney.txt", "janney-unfused.txt", "janney-relaxed.txt"):
                self.assertTrue(os.path.exists(os.path.join(out, name)), name)
            self.assertIn("--rounding relaxed", open(os.path.join(out, "janney-relaxed.txt")).read())

    def test_without_it_each_command_runs_once_as_before(self):
        with tempfile.TemporaryDirectory() as folder:
            bench = os.path.join(folder, "blastbench")
            with open(bench, "w") as f:
                f.write(FAKE)
            os.chmod(bench, 0o755)
            out = os.path.join(folder, "out")
            subprocess.run(
                [sys.executable, os.path.join(here, "concrete-matrix.py"), "--quick", "--cases", "janney",
                 "--blastbench", bench, "--out", out],
                check=True, capture_output=True, text=True)
            row = json.load(open(os.path.join(out, "matrix.json")))["cases"][0]["rows"][0]
            self.assertNotIn("roundings", row)
            self.assertFalse(os.path.exists(os.path.join(out, "janney-unfused.txt")))
            self.assertNotIn("--rounding", open(os.path.join(out, "janney.txt")).read())


if __name__ == "__main__":
    unittest.main()
