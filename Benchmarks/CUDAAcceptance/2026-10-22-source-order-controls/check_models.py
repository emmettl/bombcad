"""Analytic, symmetry and independent-model controls before saved-data scoring."""
import importlib.util
from pathlib import Path
import sys
import unittest
import numpy as np
from written_order import operator

BASE=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-host-source-matrix/analysis')
sys.path.insert(0,str(BASE))
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
engine=module('independent',BASE/'planar_euler.py')
independent=module('components',BASE/'components.py')


class Controls(unittest.TestCase):
    def test_uniform_analytic_flux(self):
        for dtype in [np.float32,np.float64]:
            w=np.tile([1.25,.125,101325.],(5,1)).astype(dtype);state=engine.conserved(w,1.5)
            r=operator(state,dtype(.001),1.5)
            expected=np.array([1.25*.125,1.25*.125**2+101325,(state[0,2]+101325)*.125],dtype=dtype)
            np.testing.assert_array_equal(r['flux'],np.tile(expected,(2,1)))
            np.testing.assert_array_equal(r['delta'],0);np.testing.assert_array_equal(r['slopes'],0)

    def test_wall_has_zero_mass_and_energy_flux_to_roundoff(self):
        for dtype in [np.float32,np.float64]:
            w=np.tile([1.225,.1,101325.],(5,1)).astype(dtype);state=engine.conserved(w,float(np.float32(1.4)))
            r=operator(state,dtype(.0001),float(np.float32(1.4)),signs=[-1,-1,1,1,1])
            bound=32*np.finfo(dtype).eps
            self.assertLessEqual(abs(r['flux'][0,0]),bound*400*1.225)
            self.assertLessEqual(abs(r['flux'][0,2]),bound*400*abs(float(state[0,2])))

    def test_reflection_symmetry(self):
        w=np.array([[1.1,-.2,101300],[1.2,.1,101330],[1.25,.4,101350],[1.3,.2,101380],[1.2,-.1,101340]],dtype=np.float64)
        state=engine.conserved(w,1.4);reflected=state[::-1].copy();reflected[:,1]*=-1
        a=operator(state,.0001,1.4)['flux'];b=operator(reflected,.0001,1.4)['flux'][::-1]*[-1,1,-1]
        np.testing.assert_allclose(a,b,rtol=2e-12,atol=2e-10)

    def test_independent_double_agreement(self):
        x=np.arange(32,dtype=np.float64)
        for w in [np.stack([1.225+.01*np.sin(x/4),.1*np.cos(x/5),101325+50*np.sin(x/3)],axis=1),np.where((x<16)[:,None],[1.,0.,1.],[.125,0.,.1])]:
            state=engine.conserved(w,1.4);stencils=np.stack([state[i-2:i+3] for i in range(2,30)])
            expected=independent.operator(engine,stencils,.0001,1.4)
            actual=operator(stencils,.0001,1.4)
            np.testing.assert_allclose(actual['flux'],expected['flux'],rtol=2e-12,atol=2e-10)
            np.testing.assert_array_equal(actual['fallback'],expected['fallback'])

    def test_refusal_and_primitive_reflection(self):
        state=engine.conserved(np.tile([1.25,0.,101325.],(5,1)),1.4)
        for args in [(state,0,1.4),(state,.001,1.),(state[:4],.001,1.4)]:
            with self.assertRaises(ValueError):operator(*args)
        with self.assertRaises(ValueError):operator(state,.001,1.4,signs=[-1,0,1,1,1])
        r=operator(state,.001,1.4,signs=[-1,-1,1,1,1]);self.assertFalse(np.signbit(r['primitive'][:,1]).any())


if __name__=='__main__':unittest.main()
