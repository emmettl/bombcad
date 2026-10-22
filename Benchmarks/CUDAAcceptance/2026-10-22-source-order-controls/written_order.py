"""Separate CPU operations following written ideal-gas 1-D shader expressions.

No claim about contraction, vector dot lowering, reciprocal/sqrt accuracy or GPU
instructions. Tangential velocity is identically zero in this restricted model.
"""
import numpy as np


def operator(state,lam,gamma,signs=None,theta=1.5,density_floor=1e-6,pressure_floor=1e-3):
    state=np.asarray(state)
    if state.dtype not in [np.dtype('float32'),np.dtype('float64')] or state.shape[-2:]!=(5,3):
        raise ValueError('five rho/mx/energy cells in Float32 or Float64 required')
    cast=state.dtype.type;prefix=state.shape[:-2]
    lam=np.broadcast_to(np.asarray(lam,dtype=state.dtype),prefix)
    if not np.isfinite(state).all() or not np.isfinite(lam).all() or np.any(lam<=0):raise ValueError('finite state and positive lambda required')
    if not all(np.isfinite(x) and x>0 for x in [theta,density_floor,pressure_floor]) or not np.isfinite(gamma) or gamma<=1:
        raise ValueError('positive supported ideal-gas configuration required')
    signs=np.ones(state.shape[:-1],dtype=np.int8) if signs is None else np.broadcast_to(signs,state.shape[:-1])
    if not np.all(np.isin(signs,[-1,1])):raise ValueError('stationary reflection signs only')
    g=cast(gamma);half=cast(.5);one=cast(1);zero=cast(0)
    rho=np.maximum(state[...,0],cast(density_floor))
    velocity=state[...,1]/rho
    # primOfCell computes physical kinetic energy before mirrored(primitive).
    pressure=np.maximum((g-one)*(state[...,2]-(half*rho)*(velocity*velocity)),cast(pressure_floor))
    velocity=np.where(signs<0,zero-velocity,velocity)
    primitive=np.stack([rho,velocity,pressure],axis=-1)
    a=primitive[...,1:-1,:]-primitive[...,:-2,:];b=primitive[...,2:,:]-primitive[...,1:-1,:]
    magnitude=np.minimum(cast(theta)*np.abs(a),np.minimum(half*np.abs(a+b),cast(theta)*np.abs(b)))
    slopes=np.where(((a>zero)&(b>zero))|((a<zero)&(b<zero)),np.where(a>zero,magnitude,-magnitude),zero)
    mid=primitive[...,1:-1,:];r,u,p=np.moveaxis(mid,-1,0);dr,du,dp=np.moveaxis(slopes,-1,0)
    h=half*lam[...,None]
    predicted=np.stack([r-h*(u*dr+r*du),u-h*(u*du+dp/r),p-h*(u*dp+(g*p)*du)],axis=-1)
    low=predicted-half*slopes;high=predicted+half*slopes
    valid=(np.minimum(low[...,0],high[...,0])>cast(density_floor))&(np.minimum(low[...,2],high[...,2])>cast(pressure_floor))
    low=np.where(valid[...,None],low,mid);high=np.where(valid[...,None],high,mid)
    left=high[...,:-1,:];right=low[...,1:,:]
    rl,ul,pl=np.moveaxis(left,-1,0);rr,ur,pr=np.moveaxis(right,-1,0)
    el=pl/(g-one)+(half*rl)*(ul*ul);er=pr/(g-one)+(half*rr)*(ur*ur)
    cl=np.sqrt((g*pl)/rl);cr=np.sqrt((g*pr)/rr)
    sl=np.sqrt(rl);sr=np.sqrt(rr);inv=one/(sl+sr)
    vr=(sl*ul+sr*ur)*inv
    hr=((sl*(el+pl))/rl+(sr*(er+pr))/rr)*inv
    sound=np.sqrt(np.maximum((g-one)*(hr-half*(vr*vr)),cast(1e-12)))
    wl=np.minimum(ul-cl,vr-sound);wr=np.maximum(ur+cr,vr+sound)
    flm=rl*ul;frm=rr*ur
    fl=np.stack([flm,flm*ul+pl,(el+pl)*ul],axis=-1)
    fr=np.stack([frm,frm*ur+pr,(er+pr)*ur],axis=-1)
    ml=rl*(wl-ul);mr=rr*(wr-ur)
    star=((pr-pl)+ul*ml-ur*mr)/(ml-mr)
    # Evaluate the selected branch only; unused star denominators can be zero.
    flux=fl.copy();back=wr<=zero;flux[back]=fr[back]
    middle=(wl<zero)&(wr>zero)
    for select,rho0,u0,p0,e0,mass,wave,physical in [
        (middle&(star>=zero),rl,ul,pl,el,ml,wl,fl),
        (middle&(star<zero),rr,ur,pr,er,mr,wr,fr)]:
        if not np.any(select):continue
        r0=rho0[select];v0=u0[select];p0=p0[select];e0=e0[select]
        m=mass[select];w=wave[select];s=star[select];f=physical[select]
        factor=m/(w-s);momentum=factor*s
        energy=factor*(e0/r0+(s-v0)*(s+p0/m))
        flux[select]=np.stack([f[:,0]+w*(factor-r0),f[:,1]+w*(momentum-r0*v0),f[:,2]+w*(energy-e0)],axis=-1)
    delta=-lam[...,None]*(flux[...,1,:]-flux[...,0,:])
    if not all(np.isfinite(x).all() for x in [primitive,slopes,predicted,flux,delta]):raise ValueError('nonfinite modeled operation')
    return dict(primitive=primitive,slopes=slopes,predicted=predicted,flux=flux,delta=delta,fallback=~valid)
