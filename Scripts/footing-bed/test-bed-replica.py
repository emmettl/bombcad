#!/usr/bin/env python3
"""The bed replica's point law, as Footing.metal's: first loading softer than unloading, the
force borne forgotten once lifted clear, and the crushing heaved back."""
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bed_replica", os.path.join(HERE, "bed_replica.py"))
replica = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replica)


def one_point(**options):
    """A bed of one point at the centre: 1 MN/m on first loading, 0.01 m², carrying 10 kN."""
    with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
        f.write("x,y,area,k\n0,0,0.01,1e6\n")
    bed = replica.Bed(f.name, capacity=1e9, weight=1e4, **options)
    os.unlink(f.name)
    return bed


class PointLaw(unittest.TestCase):
    def test_first_loading_then_stiffer_unloading(self):
        bed = one_point()
        w, _ = bed.solve(0, 0)
        # 10 kN on 1 MN/m: 10 mm down, of which the elastic share comes back.
        self.assertAlmostEqual(w, -0.01, places=6)
        force, _ = bed.step(w + 0.0012, 0, False)
        self.assertAlmostEqual(force, 0, delta=1)
        self.assertAlmostEqual(bed.sz[0], -0.01 + 0.0012, places=6)

    def test_heave_gives_back_on_lifting_clear(self):
        for heave in (0, 0.5):
            bed = one_point(heave_raw=heave)
            bed.solve(0, 0)
            crushed = bed.sz[0]
            bed.step(0.02, 0, True)  # lifted clear
            self.assertAlmostEqual(bed.sz[0], crushed * (1 - heave), places=9)
            self.assertTrue(bed.clear[0])

    def test_forgets_after_lifting_clear(self):
        bed = one_point()
        bed.solve(0, 0)
        bed.step(0.02, 0, True)
        # Landing again, it is loaded along its first curve from nothing.
        w, _ = bed.solve(0, -0.01)
        self.assertAlmostEqual(w - bed.sz[0], -0.01 * bed.es, places=6)


if __name__ == "__main__":
    unittest.main()
