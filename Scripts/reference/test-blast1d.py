"""Tests of the one-dimensional spherical blast: python3 Scripts/reference/test-blast1d.py

Coarse runs (a few seconds each); the bundled tables/blast1d-*.json are the fine ones."""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import numpy as np
    import blast1d
    import kingery_bulmash as kb
except ImportError as error:
    print(f"SKIP: {error}")
    sys.exit(0)

GAUGES = [1.0, 2.0, 3.0, 4.0]


class TNT(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = blast1d.run("tnt", 1.0, cells_charge=40, air_cell=0.008, reach=4.0, gauges=GAUGES)

    def test_energy_kept(self):
        self.assertLess(abs(self.result["energy_error"]), 1e-3)

    def test_peaks_against_kingery_bulmash_free_air(self):
        # Ideal-gas air and no afterburning: 5-8% under the curves from 2 m/kg^(1/3).
        for g in self.result["gauges"][1:]:
            r = g["peak_overpressure"] / kb.free_air(g["z"])["incident_pressure"]
            self.assertTrue(0.88 < r < 1.02, f"Z {g['z']}: {r:.3f}")

    def test_peaks_against_brode(self):
        for g in self.result["gauges"][1:]:
            r = g["peak_overpressure"] / float(blast1d.brode(g["z"]))
            self.assertTrue(1.0 < r < 1.12, f"Z {g['z']}: {r:.3f}")

    def test_arrivals(self):
        for g in self.result["gauges"][1:]:
            r = g["arrival_time"] / kb.free_air(g["z"])["arrival_time"]
            self.assertAlmostEqual(r, 1, delta=0.03, msg=f"Z {g['z']}")

    def test_impulse_short_without_afterburning(self):
        # The products' energy alone, not burnt in the air, gives 75-85% of the curves' impulse.
        for g in self.result["gauges"][1:]:
            r = g["impulse"] / kb.free_air(g["z"])["incident_impulse"]
            self.assertTrue(0.72 < r < 0.88, f"Z {g['z']}: {r:.3f}")


class Balloon(unittest.TestCase):
    def test_bombcad_balloon_against_the_jwl_charge(self):
        # BombCAD's balloon (ideal gas, 4.184 MJ/kg at 1600 kg/m^3) against the JWL charge's
        # 4.29 MJ/kg: far out the peaks within a few percent, as the energies.
        b = blast1d.run("balloon", 1.0, cells_charge=40, air_cell=0.008, reach=4.0, gauges=[3.0, 4.0],
                        balloon_density=1600.0, energy=4.184e6)
        self.assertLess(abs(b["energy_error"]), 1e-3)
        for g in b["gauges"]:
            r = g["peak_overpressure"] / kb.free_air(g["z"])["incident_pressure"]
            self.assertTrue(0.88 < r < 1.02, f"Z {g['z']}: {r:.3f}")

    def test_still_air_stays_still(self):
        e = blast1d.P0 / (0.4 * blast1d.RHO0_AIR)
        r = blast1d.run("balloon", 1.0, cells_charge=10, air_cell=0.05, reach=2.0, gauges=[1.0, 2.0],
                        balloon_density=blast1d.RHO0_AIR, energy=e)
        for g in r["gauges"]:
            self.assertLess(abs(g["peak_overpressure"]), 1e-3)


class Brode(unittest.TestCase):
    def test_fit_pieces(self):
        self.assertAlmostEqual(float(blast1d.brode(1.0)) / 1e5, 0.975 + 1.455 + 5.85 - 0.019)
        self.assertAlmostEqual(float(blast1d.brode(0.3)) / 1e5, 6.7 / 0.027 + 1)
        self.assertTrue(np.isnan(blast1d.brode(100.0)))


if __name__ == "__main__":
    unittest.main()
