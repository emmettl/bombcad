"""Conditional Double EOS evaluation of represented inputs, not native attestation."""
import math
import struct


def f32(x):return struct.unpack('<f',struct.pack('<f',x))[0]
R=f32(287.05)
THETA=[f32(3390),f32(2270)]
SHARE=[f32(.79),f32(.21)]
P=list(map(f32,[3.3791424,20.550920,137.42716,249.79498]))
Q=list(map(f32,[3.3600479,21.645931,118.98650,349.70334]))


def vibration(t):
    t=max(t,1.);energy=heat=0.
    for theta,share in zip(THETA,SHARE):
        x=min(theta/t,80.);ex=math.exp(x);below=1./(ex-1.)
        energy+=share*theta*below;heat+=share*x*x*ex*below*below
    return R*energy,R*heat


def energy_at(t):return 2.5*R*t+vibration(t)[0]


def temperature(e,method):
    if not math.isfinite(e):raise ValueError('finite internal energy required')
    if method=='source64':
        y=max(e,0.)/(2.5*R);z=y*float(f32(1./3000.))
        p=1.+z*(P[0]+z*(P[1]+z*(P[2]+z*P[3])))
        q=1.+z*(Q[0]+z*(Q[1]+z*(Q[2]+z*Q[3])))
        t=y*p/q;v,h=vibration(t)
        return max(t-(2.5*R*t+v-e)/(2.5*R+h),0.)
    if method=='root64':
        if e<=energy_at(0.):return 0.
        lo=0.;hi=max(1.,e/(2.5*R))
        for _ in range(96):
            mid=(lo+hi)/2
            if energy_at(mid)>e:hi=mid
            else:lo=mid
        return (lo+hi)/2
    raise ValueError('unsupported temperature evaluator')


def pressure(cell,uniforms,method):
    rho,mx,my,mz,total=map(float,cell)
    if not all(math.isfinite(x) for x in [rho,mx,my,mz,total]):raise ValueError('finite cell required')
    rho=max(rho,float(uniforms['densityFloor']))
    internal=total-.5*(mx*mx+my*my+mz*mz)/rho
    mode=int(uniforms['airModel'])
    if mode==0:return (float(uniforms['gamma'])-1.)*internal
    if mode==1:return rho*R*temperature(internal/rho,method)
    raise ValueError('only ideal/thermally perfect models supported')


def overpressure(row,uniforms,method,weights):
    row=list(map(float,row))
    if len(row)!=16 or row[3]<=0:raise ValueError('valid 16-field column required')
    w=row[4:6] if weights=='native' else [1.-row[2],row[2]] if weights=='column64' else None
    if w is None:raise ValueError('unsupported interpolation policy')
    return sum(weight*pressure(row[6+side*5:11+side*5],uniforms,method) for side,weight in enumerate(w) if weight>0)-float(uniforms['ambientPressure'])
