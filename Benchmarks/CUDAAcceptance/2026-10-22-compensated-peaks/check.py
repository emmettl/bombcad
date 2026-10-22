"""Analytical controls for pressure decomposition, tied maxima and physical-time coverage."""
import unittest
import numpy as np
from analyze import decompose


class Controls(unittest.TestCase):
    def test_ties_and_signed_identity(self):
        result,arrays=decompose([0,4,4,0],[0,3,3,0],[0,2,2,0],[0,1,2,3],[0,5,5,0],[0,1,2,3])
        self.assertEqual(result['native']['maximumSampleIndices'],[1,2])
        self.assertEqual(result['atNativeMaximum']['first']['termsPa'],[1.,1.,-3.,0.])
        self.assertEqual(result['atNativeMaximum']['nativePeakMinusRawFloat64PeakPa'],-1.)
        self.assertEqual(result['maximumAbsoluteThreeTermClosureResidualPa'],0.)
        np.testing.assert_array_equal(arrays['terms'].sum(axis=1),[0,-1,-1,0])

    def test_interpolation_without_extrapolation(self):
        result,arrays=decompose([0,1,2,3,4],[0,1,2,3,4],[0,1,2,3,4],[-1,0,1,2,3],[0,4],[0,2])
        self.assertEqual(result['coverageSamples'],3)
        self.assertEqual(result['uncoveredNativeMaximumIndices'],[4])
        self.assertIsNone(result['atNativeMaximum'])
        np.testing.assert_array_equal(arrays['alignedFloat64'],[0,2,4])

    def test_invalid_axes_and_values_refuse(self):
        for clock,reference in [([0,0],[0,1]),([0,1],[0,float('nan')])]:
            with self.assertRaises(ValueError):decompose([0,1],[0,1],[0,1],clock,reference,[0,1])


if __name__=='__main__':unittest.main()
