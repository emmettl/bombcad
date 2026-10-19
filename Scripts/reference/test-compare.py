"""Tests of compare.py: python3 Scripts/reference/test-compare.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
try:
    import numpy  # noqa: F401
    import compare
    import kingery_bulmash as kb
except ImportError as error:
    print(f"SKIP: {error}")
    sys.exit(0)


class SelfTest(unittest.TestCase):
    def test_self_test_passes(self):
        out = subprocess.run([sys.executable, os.path.join(HERE, "compare.py"), "--self-test"],
                             capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("0 failed", out.stdout)


class Readers(unittest.TestCase):
    def test_street_report_open_control(self):
        # The committed street benchmark: its open layout's four gauges, at slant ranges from the
        # charge 1 m up, with the layout file beside it.
        path = os.path.join(ROOT, "Benchmarks", "StreetInteraction", "m4-max", "report.json")
        gauges, burst, mass = compare.read(path)
        self.assertEqual(mass, 2.0)
        self.assertEqual(sorted(g.name for g in gauges), ["Behind", "Far street", "Front", "Street"])
        front = next(g for g in gauges if g.name == "Front")
        self.assertAlmostEqual(front.z, (36 + 49 + 0.25) ** 0.5 / 2 ** (1 / 3), places=6)

    def test_gauges_format_and_district(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = kb.at(30.0, 1000.0)
            doc = {"mass_kg": 1000.0, "burst": "surface",
                   "gauges": [{"range_m": 30.0, "peak_pa": p["incident_pressure"],
                               "impulse_pa_s": p["incident_impulse"], "arrival_s": None}]}
            path = os.path.join(tmp, "g.json")
            with open(path, "w") as f:
                json.dump(doc, f)
            rows = compare.ratios(*compare.read(path))
            self.assertAlmostEqual(rows[0]["peak_ratio"], 1.0, places=9)
            self.assertAlmostEqual(rows[0]["impulse_ratio"], 1.0, places=9)
            self.assertIsNone(rows[0]["arrival_ratio"])
            district = {"massKg": 1000.0, "line": [{"distanceM": 100.0, "peakPa": 2 * kb.at(100.0, 1000.0)["incident_pressure"]}],
                        "arrivals": []}
            path = os.path.join(tmp, "comparison.json")
            with open(path, "w") as f:
                json.dump(district, f)
            rows = compare.ratios(*compare.read(path))
            self.assertAlmostEqual(rows[0]["peak_ratio"], 2.0, places=9)

    def test_envelope_openings(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = (28.0**2 + 0.25) ** 0.5
            psi = kb.at(r, 50.0)["incident_pressure"] / compare.PSI
            path = os.path.join(tmp, "openings.json")
            with open(path, "w") as f:
                json.dump([{"chargeKg": 50.0, "targetPsi": 2, "incidentPsi": psi, "kingeryBulmashPsi": psi}], f)
            rows = compare.ratios(*compare.read(path))
            self.assertAlmostEqual(rows[0]["peak_ratio"], 1.0, places=9)

    def test_history_measures(self):
        t = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
        p = [0.0, 0.0, 100.0, 50.0, -10.0, 0.0]
        peak, impulse, arrival = compare.history_measures(t, p)
        self.assertEqual((peak, arrival), (100.0, 2.0))
        self.assertAlmostEqual(impulse, 50 + 75 + 0.5 * 50 * (50 / 60))


if __name__ == "__main__":
    unittest.main()
