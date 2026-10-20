"""Tests of the calibration's design, emulators and posterior: python3 Scripts/calibration/test-calibration.py"""

import importlib.util
import math
import os
import random
import unittest

here = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


design = load("design")
try:
    import numpy as np
    calibrate = load("calibrate")
except ImportError:  # the CI Mac's Python may lack numpy
    np = None


class DesignTests(unittest.TestCase):
    def test_today_first_then_one_point_in_each_slice_of_every_axis(self):
        rows = design.design(12, 1)
        self.assertEqual(len(rows), 13)
        self.assertEqual(rows[0], {"afterburnTime": 0.01, "ft": 1.0, "glassK": 1.0})
        for key, low, high, _ in design.PARAMETERS:
            slices = sorted(int(12 * (math.log(r[key]) - math.log(low)) / (math.log(high) - math.log(low)))
                            for r in rows[1:])
            self.assertEqual(slices, list(range(12)), key)


@unittest.skipIf(np is None, "numpy is not installed")
class EmulatorTests(unittest.TestCase):
    def test_a_smooth_function_of_one_axis_is_learnt_and_the_others_found_idle(self):
        generator = random.Random(3)
        x = np.array(design.latin_hypercube(13, 3, 2))
        y = np.array([math.log(500) - 0.4 * u[0] + 0.1 * u[0] ** 2 + 1e-4 * generator.random() for u in x])
        emulator = calibrate.Emulator(x, y)
        errors, _ = emulator.leave_one_out()
        self.assertLess(float(np.sqrt(np.mean(errors ** 2))), 0.01)
        self.assertGreater(min(emulator.lengths[1:]), emulator.lengths[0])
        mean, variance = emulator.predict(np.array([0.5, 0.5, 0.5]))
        self.assertAlmostEqual(float(mean[0]), math.log(500) - 0.2 + 0.025, delta=0.01)

    def test_runs_that_scatter_about_a_trend_give_their_scatter_not_a_wiggle(self):
        generator = random.Random(5)
        x = np.array(design.latin_hypercube(13, 3, 2))
        y = np.array([0.1 * u[1] + generator.gauss(0, 0.05) for u in x])
        emulator = calibrate.Emulator(x, y, active=[1])
        self.assertGreater(emulator.nugget, 0.02)
        # Only its own axis moves it.
        a, _ = emulator.predict(np.array([0.1, 0.5, 0.9]))
        b, _ = emulator.predict(np.array([0.9, 0.5, 0.1]))
        self.assertAlmostEqual(float(a[0]), float(b[0]), places=12)


@unittest.skipIf(np is None, "numpy is not installed")
class PosteriorTests(unittest.TestCase):
    def items(self, truth, bias=0.0):
        """Comparisons of one regime, each moved by the first parameter differently, measured where
        the model gives them at `truth` (times a shared discrepancy)."""
        x = np.array(design.latin_hypercube(13, 3, 4))
        items = []
        for slope in (-0.2, -0.4, -0.8):
            y = np.array([slope * u[0] for u in x])
            items.append(dict(case="c", output=str(slope), regime="r", emulator=calibrate.Emulator(x, y, active=[0]),
                              logMeasured=slope * truth + bias, sigma=0.02))
        return items

    def test_without_discrepancy_the_truth_is_found(self):
        posterior = calibrate.Posterior(self.items(0.3), discrepancy=False)
        chain = posterior.sample(600, seed=2)
        self.assertAlmostEqual(float(np.median(chain[:, 0])), 0.3, delta=0.05)
        # The idle parameters stay as wide as their prior.
        self.assertGreater(float(np.std(chain[:, 1])), 0.25)

    def test_a_shared_discrepancy_widens_what_the_comparisons_say(self):
        items = self.items(0.3, bias=0.1)
        tight = calibrate.Posterior(items, discrepancy=False).sample(600, seed=2)
        loose = calibrate.Posterior(items, discrepancy=True).sample(600, seed=2)
        self.assertGreater(float(np.std(loose[:, 0])), 1.5 * float(np.std(tight[:, 0])))


if __name__ == "__main__":
    unittest.main()
