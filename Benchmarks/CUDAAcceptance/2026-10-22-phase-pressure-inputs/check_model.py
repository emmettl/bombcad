import math
import unittest
from pressure_model import R,energy_at,temperature,pressure,overpressure


class Controls(unittest.TestCase):
    def test_source_temperature_against_independent_root(self):
        for t in [1.,100.,288.15,300.,1000.,10000.,60000.]:
            e=energy_at(t);root=temperature(e,'root64');approx=temperature(e,'source64')
            self.assertLessEqual(abs(root-t),1e-8+2e-14*t)
            self.assertLessEqual(abs(approx-root),1e-8+2e-8*t)

    def test_pressure_density_and_velocity(self):
        for rho in [.1,1.225,10.]:
            for t in [1.,288.15,1000.,60000.]:
                v=.125;cell=[rho,rho*v,0.,0.,rho*energy_at(t)+.5*rho*v*v]
                u=dict(densityFloor=1e-6,airModel=1,gamma=1.4,ambientPressure=101325.)
                self.assertAlmostEqual(pressure(cell,u,'root64')/(rho*R*t),1.,places=12)

    def test_ideal_gas_analytic(self):
        u=dict(densityFloor=1e-6,airModel=0,gamma=1.5,ambientPressure=0.)
        self.assertEqual(pressure([2.,4.,0.,0.,104.],u,'root64'),50.)

    def test_interpolation_and_refusal(self):
        u=dict(densityFloor=1e-6,airModel=0,gamma=1.5,ambientPressure=0.)
        row=[0,1,.25,1,.75,.25,2,0,0,0,200,2,0,0,0,400]
        for weights in ['native','column64']:self.assertEqual(overpressure(row,u,'source64',weights),125.)
        with self.assertRaises(ValueError):pressure([1,0,0,0,1],dict(u,airModel=2),'source64')
        with self.assertRaises(ValueError):temperature(math.nan,'source64')
        with self.assertRaises(ValueError):overpressure(row,u,'source64','unknown')


if __name__=='__main__':unittest.main()
