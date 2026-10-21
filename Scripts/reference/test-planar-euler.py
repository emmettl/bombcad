import math
import unittest
import sys
try:
    import numpy as np
    from planar_euler import primitive, conserved, flux, advance, advance_mixed
except ImportError as error:
    print(f"SKIP: {error}")
    sys.exit(0)


def sod_density(x, time, g=1.4):
    rl, pl, rr, pr = 1., 1., .125, .1
    cl, cr = math.sqrt(g*pl/rl), math.sqrt(g*pr/rr)
    def f(p,rho,p0,c):
        if p>p0:return (p-p0)*math.sqrt(2/((g+1)*rho)/(p+(g-1)/(g+1)*p0))
        return 2*c/(g-1)*((p/p0)**((g-1)/(2*g))-1)
    low,high=1e-8,2.
    for _ in range(100):
        p=(low+high)*.5
        if f(p,rl,pl,cl)+f(p,rr,pr,cr)>0:high=p
        else:low=p
    p=(low+high)*.5; u=.5*(f(p,rr,pr,cr)-f(p,rl,pl,cl))
    s=(x-.5)/time; cstar=cl*(p/pl)**((g-1)/(2*g))
    if s < -cl:return rl
    if s < u-cstar:
        c=2/(g+1)*(cl-(g-1)*s/2)
        return rl*(c/cl)**(2/(g-1))
    if s < u:return rl*(p/pl)**(1/g)
    shock=cr*math.sqrt((g+1)/(2*g)*p/pr+(g-1)/(2*g))
    if s < shock:return rr*(p/pr+(g-1)/(g+1))/((g-1)/(g+1)*p/pr+1)
    return rr


class EulerTests(unittest.TestCase):
    def test_flux_and_contact(self):
        l=np.array([[1.,.3,1.]])
        r=np.array([[2.,.3,1.]])
        expected=np.array([[.3,1.09,(1/.4+.5*.3**2+1)*.3]])
        np.testing.assert_allclose(flux(l,l,1.4),expected,rtol=1e-14,atol=1e-14)
        np.testing.assert_allclose(flux(l,r,1.4),expected,rtol=1e-14,atol=1e-14)
        mirror=l.copy();mirror[:,1]*=-1
        wall=flux(mirror,l,1.4)
        np.testing.assert_allclose(wall[:,[0,2]],0,atol=1e-14)
    def test_rest_and_dtypes(self):
        for dtype in [np.float32,np.float64]:
            w=np.tile(np.array([1.225,0,101325],dtype=dtype),(32,1))
            state=conserved(w,1.4)
            result,stats=advance(state,.0001,.25,1.4)
            np.testing.assert_array_equal(result,state)
            self.assertEqual(result.dtype,dtype)
            self.assertEqual(stats['reconstructionFallback'],0)
            for evaluation in [np.float32, np.float64]:
                mixed, diagnostics = advance_mixed(state,.0001,.25,1.4,evaluation_dtype=evaluation)
                np.testing.assert_array_equal(mixed,state)
                self.assertEqual(mixed.dtype,dtype)
                self.assertEqual(diagnostics['reconstructionFallback'],0)
    def test_sod_totals_and_refinement(self):
        errors=[]
        for n in [128,256]:
            dx=1/n;x=(np.arange(n)+.5)*dx
            w=np.stack((np.where(x<.5,1.,.125),np.zeros(n),np.where(x<.5,1.,.1)),axis=1)
            state=conserved(w,1.4);start=np.sum(state,axis=0)*dx;boundary=np.zeros(3);t=0.
            while t<.1:
                p=primitive(state,1.4)
                speed=np.max(np.abs(p[:,1])+np.sqrt(1.4*p[:,2]/p[:,0]))
                dt=min(.4*dx/speed,.1-t)
                state,stats=advance(state,dt,dx,1.4);t+=dt;boundary+=stats['boundaryFlux']
            np.testing.assert_allclose(np.sum(state,axis=0)*dx-start+boundary,0,atol=2e-14)
            self.assertAlmostEqual(np.sum(state[:,1])*dx,.09,places=11)
            errors.append(float(np.mean(np.abs(state[:,0]-np.array([sod_density(a,.1) for a in x])))))
        self.assertLess(errors[1],errors[0]);self.assertLess(errors[0],.02)
    def test_nonphysical_state_is_refused(self):
        with self.assertRaises(ValueError):primitive(np.array([[1.,0.,-1.],[1.,0.,2.]]),1.4)

if __name__=='__main__':unittest.main()
