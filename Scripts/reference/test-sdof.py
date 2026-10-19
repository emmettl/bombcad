"""Tests of the Biggs SDOF reference: python3 Scripts/reference/test-sdof.py"""

import math
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sdof  # noqa: E402  (pure Python)

TWO_PI = 2 * math.pi


def unit_member(ultimate, support="simple", load="uniform"):
    """An elastic-perfectly plastic member with an elastic period of 1 s on its elastic K_LM."""
    klm = sdof.load_mass_factor(support, load, "elastic")
    return sdof.elastic_plastic(1.0, TWO_PI**2 * klm, ultimate, support, load)


class TransformationFactors(unittest.TestCase):
    def test_load_mass_factors_as_tabulated(self):
        # Biggs Table 5.1 / UFC 3-340-02 Table 3-12's K_LM, to their two figures.
        expected = {("simple", "uniform"): (0.78, 0.66), ("fixed", "uniform"): (0.77, 0.66),
                    ("cantilever", "uniform"): (0.65, 0.66), ("simple", "point"): (0.49, 0.33),
                    ("fixed", "point"): (0.37, 0.33), ("cantilever", "point"): (0.24, 0.33)}
        for (support, load), (el, pl) in expected.items():
            self.assertAlmostEqual(sdof.load_mass_factor(support, load, "elastic"), el, delta=0.006)
            self.assertAlmostEqual(sdof.load_mass_factor(support, load, "plastic"), pl, delta=0.006)
        self.assertAlmostEqual(sdof.load_mass_factor("fixed", "uniform", "elastoplastic"), 0.78, delta=0.006)

    def test_fixed_member_equivalent_stiffness(self):
        # UFC 3-340-02 Table 3-8: K_E = 307 EI / L^4 for a fixed member, uniform load, equal moments.
        m = sdof.beam(5.0, 300.0, 2e7, "fixed", "uniform", 1e5)
        ke = m.ultimate / m.equivalent_elastic_deflection
        self.assertAlmostEqual(ke / (307 * 2e7 / 5.0**3), 1, delta=0.002)

    def test_simple_beam_resistance_and_period(self):
        m = sdof.beam(4.0, 400.0, 1e7, "simple", "uniform", 5e4)
        self.assertAlmostEqual(m.ultimate, 8 * 5e4 / 4.0)
        self.assertAlmostEqual(m.stiffness, 384 * 1e7 / (5 * 4.0**3))
        period = TWO_PI * math.sqrt(0.78 * 1600.0 / m.stiffness)
        self.assertAlmostEqual(m.natural_period() / period, 1, delta=0.01)


class ClosedForms(unittest.TestCase):
    def test_elastic_triangular_dlf_limits(self):
        self.assertAlmostEqual(sdof.elastic_triangular_dlf(1e-3) / (math.pi * 1e-3), 1, delta=0.002)
        self.assertAlmostEqual(sdof.elastic_triangular_dlf(200.0), 2.0, delta=0.01)
        self.assertAlmostEqual(sdof.elastic_triangular_dlf(1.0), 1.55, delta=0.01)  # the closed form at t_d / T = 1

    def test_integrator_matches_the_closed_form_elastic_response(self):
        m = unit_member(1e9)  # never yields
        for td in (0.05, 0.2, 0.5, 1.0, 3.0):
            _, xs, _ = sdof.respond(m, sdof.triangular(1.0, td))
            dlf = max(xs) * m.stiffness
            self.assertAlmostEqual(dlf / sdof.elastic_triangular_dlf(td), 1, delta=0.005, msg=f"td/T {td}")

    def test_impulsive_ductility(self):
        m = unit_member(0.2)
        for td in (0.002, 0.004):
            pulse = sdof.triangular(60.0, td)
            mu = sdof.peak_ductility(m, pulse, constant_factor=0.78, dt=td / 40)
            ref = sdof.impulsive_ductility(30.0 * td, m)
            self.assertGreater(ref, 2.0)
            self.assertAlmostEqual(mu / ref, 1, delta=0.03, msg=f"td {td}")

    def test_suddenly_applied_constant_load(self):
        for ratio in (1.1, 1.25, 1.6):
            m = unit_member(ratio)
            mu = sdof.peak_ductility(m, [(0.0, 1.0), (100.0, 1.0)], until=2.0, constant_factor=0.78)
            self.assertAlmostEqual(mu / sdof.step_ductility(ratio), 1, delta=0.005, msg=f"ratio {ratio}")

    def test_long_triangular_pulse_approaches_the_step(self):
        m = unit_member(1.25)
        mu = sdof.peak_ductility(m, sdof.triangular(1.0, 50.0), until=3.0, constant_factor=0.78)
        self.assertAlmostEqual(mu / sdof.step_ductility(1.25), 1, delta=0.05)


class Behaviour(unittest.TestCase):
    def test_permanent_set_after_yield(self):
        m = unit_member(0.5)
        ts, xs, rs = sdof.respond(m, sdof.triangular(2.0, 0.5), constant_factor=0.78)
        late = [x for t, x in zip(ts, xs) if t > ts[-1] - 1.0]
        centre = 0.5 * (max(late) + min(late))
        self.assertGreater(centre, 0.5 * m.elastic_limit)  # it oscillates about a set
        self.assertLessEqual(max(abs(r) for r in rs), m.ultimate * (1 + 1e-9))

    def test_bilinear_pulse_impulse(self):
        pulse = sdof.bilinear(100.0, 0.01, 20.0, 0.05)
        self.assertAlmostEqual(sdof._impulse(pulse), 0.5 * 120 * 0.01 + 0.5 * 20 * 0.04)

    def test_load_mass_factor_switches_with_regime(self):
        # The velocity carries across the change of factor, so passing to the smaller plastic K_LM
        # leaves less kinetic energy: the member goes less far than with the elastic one held.
        m = unit_member(0.5)
        pulse = sdof.triangular(2.0, 0.3)
        switching = sdof.peak_ductility(m, pulse)
        held = sdof.peak_ductility(m, pulse, constant_factor=0.78)
        self.assertLess(switching, held)
        self.assertGreater(switching, 0.9 * held)


if __name__ == "__main__":
    unittest.main()
