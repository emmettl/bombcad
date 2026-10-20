"""The field model's run list: as planned, within its bounds, and the runs' arguments."""

import importlib.util
import json
import math
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


field_runs = load("field_runs", "field-runs.py")
make_district = load("make_district", "make_district.py")


class RunListTests(unittest.TestCase):
    def setUp(self):
        with open(HERE / "field-runs.json") as handle:
            self.data = json.load(handle)

    def test_the_committed_list_is_the_plan(self):
        planned = json.loads(json.dumps(field_runs.with_estimates(field_runs.plan(), self.data["costModel"])))
        self.assertEqual(planned, self.data, "rerun: python3 -I Scripts/ml/field-runs.py plan")

    def test_its_bounds(self):
        runs = self.data["sets"]["main"]
        self.assertTrue(180 <= len(runs) <= 220, len(runs))
        self.assertEqual(len({run["id"] for run in runs}), len(runs))
        for run in runs:
            self.assertTrue(50_000 <= run["massKg"] <= 2_000_000, run)
            self.assertLessEqual(run["estimate"]["seconds"], field_runs.MAX_SECONDS, run)
            self.assertIn(run["layout"], self.data["layouts"])
        self.assertEqual(sum(run["layout"] == "beirut" for run in runs), 50)
        # Yields spread over the range: each fifth of the log range is about a fifth of the runs.
        span = math.log(2 / 0.05)
        fifths = [0] * 5
        for run in runs:
            fifths[min(4, int(5 * math.log(run["massKg"] / 50_000) / span))] += 1
        self.assertTrue(all(30 <= n <= 50 for n in fifths), fifths)
        total = self.data["totals"]["main"]
        self.assertAlmostEqual(total["gpuHours"], sum(r["estimate"]["seconds"] for r in runs) / 3600, places=1)

    def test_a_runs_arguments(self):
        run = {"id": "made-grid-s1-1", "layout": "made-grid-s1", "offsetM": [100, -50], "massKg": 200000,
               "radiusM": 1024}
        layout = self.data["layouts"]["made-grid-s1"]
        inputs = {"osm": "/l/district.osm", "dem": None, "heights": None, "extra": []}
        arguments = field_runs.field_arguments(run, layout, inputs, "/d/runs/made-grid-s1-1")
        self.assertEqual(arguments[:3], ["field-export", "--osm", "/l/district.osm"])
        self.assertNotIn("--dem", arguments)
        value = lambda name: arguments[arguments.index(name) + 1]
        self.assertEqual(value("--mass"), "200000")
        self.assertEqual(value("--radius"), "1024")
        self.assertEqual(value("--dx"), "4")
        self.assertEqual(value("--out"), "/d/runs/made-grid-s1-1")
        lon, lat = (float(v) for v in value("--centre").split(","))
        # The charge 100 m east and 50 m south of the district's middle.
        middle = layout["extentM"] / 2 / field_runs.M
        self.assertAlmostEqual((lon - middle) * field_runs.M, 100, delta=0.01)
        self.assertAlmostEqual((lat - middle) * field_runs.M, -50, delta=0.01)
        beirut = field_runs.field_arguments(dict(run, layout="beirut", offsetM=[0, 0]), self.data["layouts"]["beirut"],
                                            field_runs.BEIRUT_INPUTS, "out")
        self.assertIn("--heights", beirut)
        self.assertEqual(beirut[beirut.index("--centre") + 1], "35.51904200,33.90142500")

    def test_durations_follow_kingery_bulmash(self):
        # FieldExport.duration for 50 t over a 512 m half side is 2.23 s (the smoke run's).
        self.assertAlmostEqual(field_runs.until(512, 50_000), 2.23, delta=0.07)


class DistrictTests(unittest.TestCase):
    def test_same_arguments_same_district(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            first = make_district.write(a, "mixed", 4, 900, "hill")
            second = make_district.write(b, "mixed", 4, 900, "hill")
            self.assertEqual(Path(first["osm"]).read_text(), Path(second["osm"]).read_text())
            self.assertEqual(Path(first["dem"]).read_text(), Path(second["dem"]).read_text())
            self.assertGreater(first["buildings"], 20)

    def test_every_style(self):
        for style in make_district.STYLES:
            with tempfile.TemporaryDirectory() as folder:
                made = make_district.write(folder, style, 1, 800, "flat")
                self.assertIsNone(made["dem"])
                self.assertGreater(made["buildings"], 3, style)


if __name__ == "__main__":
    unittest.main()
