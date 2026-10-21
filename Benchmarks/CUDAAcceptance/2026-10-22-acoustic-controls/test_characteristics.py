import math
import unittest
from characteristics import interpolate, split, pressure_at

class CharacteristicsTests(unittest.TestCase):
    def test_affine_interpolation(self):
        self.assertEqual(interpolate([1,3,5],.5,.5),2)
        self.assertEqual(interpolate([1,3,5],.5,-10),1)
        self.assertEqual(interpolate([1,3,5],.5,10),5)
    def test_constant_pressure_and_wall(self):
        parts=split([2]*32,[0]*32,1.225,340)
        for x,t in [(0,0),(0,1),(4,.01),(4,.02)]:
            self.assertEqual(pressure_at(parts,.5,340,x,t),2)
    def test_travelling_and_reflected_packet(self):
        dx=.015625; c=340.; rho=1.225
        p=[-math.sin(math.pi*((i+.5)*dx-8)) if abs((i+.5)*dx-8)<1 else 0 for i in range(1024)]
        parts=split(p,[-a/(rho*c) for a in p],rho,c)
        for x,t,expected in [(4,3.5/c,1),(4,11.5/c,1),(0,7.5/c,2),(4,4.5/c,-1)]:
            self.assertLess(abs(pressure_at(parts,dx,c,x,t)-expected),.0007)
        for i in range(1024):
            self.assertAlmostEqual(pressure_at(parts,dx,c,(i+.5)*dx,0),p[i],places=14)
if __name__=='__main__': unittest.main()
