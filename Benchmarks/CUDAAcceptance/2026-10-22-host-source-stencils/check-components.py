import importlib.util
from pathlib import Path
import unittest
import numpy as np
from components import operator

here=Path(__file__).resolve().parent
engine_path=here/'planar_euler.py'
if not engine_path.exists():engine_path=here.parents[2]/'Scripts/reference/planar_euler.py'
spec=importlib.util.spec_from_file_location('euler',engine_path)
engine=importlib.util.module_from_spec(spec);spec.loader.exec_module(engine)


class Controls(unittest.TestCase):
    def test_uniform_analytic_flux(self):
        gamma=float(np.float32(1.4));w=np.tile([1.25,.125,101325.],(5,1));state=engine.conserved(w,gamma)
        result=operator(engine,state,.001,gamma);expected=[1.25*.125,1.25*.125**2+101325,(state[0,2]+101325)*.125]
        np.testing.assert_array_equal(result['slopes'],0)
        np.testing.assert_array_equal(result['flux'],np.tile(expected,(2,1)))
        np.testing.assert_array_equal(result['updated'],state[2]);self.assertFalse(result['fallback'].any())

    def test_matches_full_array_centre(self):
        for dtype in [np.float32,np.float64]:
            gamma=float(np.float32(1.4));x=np.arange(32,dtype=np.float64)
            for w in [np.stack([1.225+.01*np.sin(x/4),.1*np.cos(x/5),101325+50*np.sin(x/3)],axis=1),np.where((x<16)[:,None],[1.,0.,1.],[.125,0.,.1])]:
                state=engine.conserved(w.astype(dtype),gamma);dt=float(np.float32(1e-5));dx=.25
                actual,_=engine.advance(state,dt,dx,gamma)
                stencils=np.stack([state[i-2:i+3] for i in range(2,30)])
                result=operator(engine,stencils,dtype(dt)/dtype(dx),gamma)
                np.testing.assert_array_equal(result['updated'],actual[2:30])

    def test_refusal_and_rounding_scope(self):
        state=engine.conserved(np.tile([1.225,0.,101325.],(5,1)),1.4)
        with self.assertRaises(ValueError):operator(engine,state,0,1.4)
        with self.assertRaises(ValueError):operator(engine,state,.001,1.4,round_after='unknown')
        for stage in ['primitive','slope','faces']:
            result=operator(engine,state,.001,1.4,round_after=stage);self.assertTrue(np.isfinite(result['flux']).all())


if __name__=='__main__':unittest.main()
