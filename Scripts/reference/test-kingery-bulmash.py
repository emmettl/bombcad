"""Tests of the Kingery-Bulmash and oblique reflection references:
python3 Scripts/reference/test-kingery-bulmash.py"""

import json
import math
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import numpy as np
    import kingery_bulmash as kb
    import oblique
except ImportError as error:  # NumPy is the references' one dependency
    print(f"SKIP: {error}")
    sys.exit(0)

P0 = 101325.0


class TabulatedValues(unittest.TestCase):
    def test_iatg_worked_examples_within_one_percent(self):
        # IATG 01.80 Table 5: 1, 10 and 100 t at 50 m (Z 5, 2.32 and 1.08).
        with open(os.path.join(HERE, "tables", "iatg-01.80-table5.json")) as f:
            table = json.load(f)
        for row in table["rows"]:
            a = kb.at(row["range_m"], row["mass_kg"])
            self.assertAlmostEqual(a["incident_pressure"] / 1e5 / row["incident_bar"], 1, delta=0.01)
            self.assertAlmostEqual(a["reflected_pressure"] / 1e5 / row["reflected_bar"], 1, delta=0.01)
            self.assertAlmostEqual(a["incident_impulse"] / 100 / row["incident_impulse_bar_ms"], 1, delta=0.01)
            self.assertAlmostEqual(a["reflected_impulse"] / 100 / row["reflected_impulse_bar_ms"], 1, delta=0.01)
            self.assertAlmostEqual(a["arrival_time"] * 1e3 / row["arrival_ms"], 1, delta=0.01)


class Consistency(unittest.TestCase):
    """The fits are independent of one another, so a slip in any coefficient shows against the
    Rankine-Hugoniot relations that tie them together far from the charge."""

    z = np.geomspace(4.0, 39.0, 60)

    def test_reflected_pressure_follows_rankine_hugoniot_far_out(self):
        p = kb.hemispherical(self.z)
        ps = p["incident_pressure"]
        rh = 2 * ps * (7 * P0 + 4 * ps) / (7 * P0 + ps)
        np.testing.assert_allclose(p["reflected_pressure"] / rh, 1, atol=0.02)

    def test_shock_speed_follows_rankine_hugoniot_from_2(self):
        z = np.geomspace(2.0, 39.0, 60)
        p = kb.hemispherical(z)
        u = 340.3 * np.sqrt(1 + 6 * p["incident_pressure"] / (7 * P0))
        np.testing.assert_allclose(p["shock_velocity"] / u, 1, atol=0.015)

    def test_arrival_time_is_the_integral_of_the_shock_speed(self):
        z = np.geomspace(0.3, 35.0, 400)
        p = kb.hemispherical(z)
        speed = 1 / np.gradient(p["arrival_time"], z)
        np.testing.assert_allclose(speed / p["shock_velocity"], 1, atol=0.05)

    def test_pieces_meet(self):
        for name, pieces in (("incident_impulse", kb.INCIDENT_IMPULSE), ("positive_duration", kb.POSITIVE_DURATION)):
            for (lo, hi), *_ in pieces[1:]:
                below = kb.hemispherical(lo * 0.9999)[name]
                above = kb.hemispherical(lo * 1.0001)[name]
                self.assertAlmostEqual(above / below, 1, delta=0.02, msg=f"{name} at {lo}")


class Scaling(unittest.TestCase):
    def test_free_air_is_a_surface_burst_of_w_over_1_8(self):
        free = kb.at(10.0, 18.0, "free")
        surface = kb.at(10.0, 10.0, "surface")
        for k in free:
            self.assertAlmostEqual(free[k] / surface[k], 1, places=12)

    def test_cube_root_scaling(self):
        a, b = kb.at(5.0, 1.0), kb.at(50.0, 1000.0)
        self.assertAlmostEqual(a["incident_pressure"], b["incident_pressure"])
        self.assertAlmostEqual(b["arrival_time"] / a["arrival_time"], 10.0)

    def test_nan_outside_the_fits(self):
        self.assertTrue(math.isnan(kb.hemispherical(0.05)["incident_pressure"]))
        self.assertTrue(math.isnan(kb.hemispherical(41.0)["incident_pressure"]))
        self.assertTrue(math.isnan(kb.hemispherical(0.1)["positive_duration"]))


class ObliqueReflection(unittest.TestCase):
    def test_head_on_is_rankine_hugoniot(self):
        for ratio in (0.01, 0.5, 5.0, 50.0):
            rh = 2 * (7 + 4 * ratio) / (7 + ratio)
            self.assertAlmostEqual(oblique.coefficient(ratio, 0.0), rh, places=9)
            self.assertAlmostEqual(oblique.coefficient(ratio, math.radians(1.0)), rh, delta=0.01 * rh)

    def test_grazing_is_one(self):
        for ratio in (0.1, 3.0):
            self.assertEqual(oblique.coefficient(ratio, math.pi / 2), 1.0)

    def test_weak_shock_reflects_acoustically(self):
        # An acoustic wave doubles at any angle short of grazing.
        for deg in (0, 20, 40, 60):
            self.assertAlmostEqual(oblique.regular(1e-4, math.radians(deg)), 2.0, delta=0.002)

    def test_strong_shock_detachment_angle(self):
        # For gamma 1.4 the detachment angle falls to about 39-40 degrees for strong shocks and
        # rises towards 90 as the shock weakens (Ben-Dor 2007, chapter 1).
        self.assertTrue(38.5 < math.degrees(oblique.detachment_angle(100.0)) < 41.0)
        self.assertGreater(math.degrees(oblique.detachment_angle(0.01)), 75.0)
        a = [oblique.detachment_angle(r) for r in (0.03, 0.1, 0.3, 1.0)]
        self.assertTrue(all(x > y for x, y in zip(a, a[1:])))

    def test_coefficient_continuous_through_detachment(self):
        ratio = 1.0
        a = oblique.detachment_angle(ratio)
        self.assertAlmostEqual(oblique.coefficient(ratio, a - 1e-6), oblique.coefficient(ratio, a + 1e-6), delta=0.01)

    def test_ufc_implied_coefficient_head_on_matches_the_ideal_gas_for_weak_shocks(self):
        # Figure 2-9 over Kingery-Bulmash, head-on, at 30 kPa: about 2.2, the ideal gas 2.24.
        c = oblique.ufc_coefficient(30e3, 0.0)
        self.assertAlmostEqual(c / oblique.normal_coefficient(30e3 / P0), 1, delta=0.05)


if __name__ == "__main__":
    unittest.main()
