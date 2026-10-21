#!/usr/bin/env python3
"""CPU tensor tests for cooling bounds; run in the existing PC PyTorch environment."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
try:import torch
except ImportError:torch=None
import run as worker


@unittest.skipIf(torch is None,'PyTorch environment required; these tests need no GPU')
class CoolingBoundsTests(unittest.TestCase):
    def test_empty_medium_has_no_dispatch_box(self):
        medium=torch.zeros((3*4*5,2))
        self.assertIsNone(worker.luminous_bounds(medium,(5,4,3)))

    def test_radiance_without_opacity_does_not_emit_or_absorb(self):
        medium=torch.zeros((3*4*5,2));medium[:,1]=1e8
        self.assertIsNone(worker.luminous_bounds(medium,(5,4,3)))

    def test_single_cell_uses_xyz_order_on_non_cubic_grid(self):
        medium=torch.zeros((3*4*5,2));medium[4+5*(2+4*1),0]=.1
        self.assertEqual(worker.luminous_bounds(medium,(5,4,3)),[4,2,1,4,2,1])

    def test_disjoint_cells_include_the_transparent_gap(self):
        medium=torch.zeros((3*4*5,2));medium[1+5*(1+4*0),0]=.1;medium[4+5*(3+4*2),0]=.2
        self.assertEqual(worker.luminous_bounds(medium,(5,4,3)),[1,1,0,4,3,2])


if __name__=='__main__':unittest.main()
