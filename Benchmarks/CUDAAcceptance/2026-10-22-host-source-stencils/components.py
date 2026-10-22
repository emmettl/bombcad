"""Independent local Euler component counterfactuals, never observed GPU intermediates."""
import numpy as np


def operator(engine,state,lam,gamma,theta=1.5,density_floor=1e-6,pressure_floor=1e-3,round_after=None):
    state=np.asarray(state);shape=state.shape
    if state.dtype not in [np.dtype('float32'),np.dtype('float64')] or shape[-2:]!=(5,3):raise ValueError('five conserved rho/mx/energy cells required')
    if round_after not in [None,'primitive','slope','faces']:raise ValueError('unknown staged rounding counterfactual')
    cast=state.dtype.type;prefix=shape[:-2];lam=np.broadcast_to(np.asarray(lam,dtype=state.dtype),prefix)
    if not np.isfinite(lam).all() or np.any(lam<=0):raise ValueError('positive finite lambda required')
    def rounded(value,stage):return value.astype(np.float32).astype(state.dtype) if round_after==stage else value
    primitive=rounded(engine.primitive(state.reshape(-1,3),gamma).reshape(shape),'primitive')
    a=primitive[...,1:-1,:]-primitive[...,:-2,:];b=primitive[...,2:,:]-primitive[...,1:-1,:]
    magnitude=np.minimum(cast(theta)*np.abs(a),np.minimum(cast(.5)*np.abs(a+b),cast(theta)*np.abs(b)))
    slopes=rounded(np.where(((a>0)&(b>0))|((a<0)&(b<0)),np.copysign(magnitude,a),cast(0)),'slope')
    mid=primitive[...,1:-1,:];rho,u,p=np.moveaxis(mid,-1,0);dr,du,dp=np.moveaxis(slopes,-1,0)
    half=cast(.5)*lam[...,None]
    predicted=np.stack([rho-half*(u*dr+rho*du),u-half*(u*du+dp/rho),p-half*(u*dp+cast(gamma)*p*du)],axis=-1)
    low=predicted-cast(.5)*slopes;high=predicted+cast(.5)*slopes
    valid=(np.minimum(low[...,0],high[...,0])>cast(density_floor))&(np.minimum(low[...,2],high[...,2])>cast(pressure_floor))
    low=np.where(valid[...,None],low,mid);high=np.where(valid[...,None],high,mid)
    faces=rounded(np.stack([low,high],axis=-2),'faces')
    left=np.stack([faces[...,0,1,:],faces[...,1,1,:]],axis=-2)
    right=np.stack([faces[...,1,0,:],faces[...,2,0,:]],axis=-2)
    flux=engine.flux(left.reshape(-1,3),right.reshape(-1,3),gamma).reshape(*prefix,2,3)
    delta=-lam[...,None]*(flux[...,1,:]-flux[...,0,:])
    if not all(np.isfinite(x).all() for x in [primitive,slopes,predicted,faces,flux,delta]):raise ValueError('nonfinite local counterfactual')
    return dict(primitive=primitive,slopes=slopes,predicted=predicted,faces=faces,flux=flux,delta=delta,
                fallback=~valid,updated=state[...,2,:]+delta)


def mapped_state(conserved_bits,residual_bits,signs,paired=False):
    state=np.asarray(conserved_bits,dtype=np.uint32).view(np.float32).astype(np.float64)
    residual=np.asarray(residual_bits,dtype=np.uint32).view(np.float32).astype(np.float64)
    if state.shape[-2:]!=(5,5) or residual.shape!=state.shape[:-1]+(4,):raise ValueError('canonical physical source shape')
    if np.any(state[...,2:4]!=0):raise ValueError('one-dimensional momentum required')
    result=state[...,[0,1,4]].copy()
    if paired:result[...,0]-=residual[...,0];result[...,2]-=residual[...,1]
    signs=np.asarray(signs)
    if not np.all(np.isin(signs,[-1,1])):raise ValueError('declared reflection signs required')
    result[...,1]*=signs
    return result
