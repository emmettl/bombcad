"""Draft analysis-only Double projections and cancellation-resistant conserved changes."""
import math
import numpy as np


def history(trace,initial_residual_words,gamma):
    raw=np.asarray(trace['valueBits'],dtype=np.uint32)
    active=np.asarray(trace['executed'],dtype=bool)
    initial=np.asarray(trace['initialStateBits'],dtype=np.uint32)
    residual=np.asarray(initial_residual_words,dtype=np.uint32)
    n,m=active.shape
    if raw.shape!=(n,m,33) or initial.shape!=(m,5):raise ValueError('trace shape')
    state=initial.view(np.float32).astype(np.float64)
    error=residual[trace['indices'],:2].copy().view(np.float32).astype(np.float64)
    stored=np.empty((n+1,m),dtype=np.float64);corrected=np.empty_like(stored)
    def project():
        if not np.all(state[:,2:4]==0):raise ValueError('fixed one-dimensional momentum required')
        if np.any(state[:,0]<=0) or np.any(state[:,0]-error[:,0]<=0):raise ValueError('positive density required')
        velocity=state[:,1]/state[:,0]
        a=(gamma-1)*(state[:,4]-.5*state[:,1]*velocity)-101325
        # This is a Double readout counterfactual, not the pressure consumed by the GPU.
        rho=state[:,0]-error[:,0];energy=state[:,4]-error[:,1]
        b=(gamma-1)*(energy-.5*state[:,1]*(state[:,1]/rho))-101325
        return a,b
    stored[0],corrected[0]=project()
    v=raw.view(np.float32)
    for i in range(n):
        yes=active[i];state[yes]=v[i,yes,5:10];error[yes]=v[i,yes,26:28]
        stored[i+1],corrected[i+1]=project()
    return stored,corrected


def conserved_changes(initial,final,initial_residual_words,final_residual_words,dx):
    # JSON state decimals must be restored to Float32 before widening.
    begin=np.asarray(initial,dtype=np.float32).astype(np.float64)
    end=np.asarray(final,dtype=np.float32).astype(np.float64)
    a=np.asarray(initial_residual_words,dtype=np.uint32).view(np.float32)
    b=np.asarray(final_residual_words,dtype=np.uint32).view(np.float32)
    if begin.shape!=end.shape or begin.ndim!=2 or begin.shape[1]!=3 or a.shape!=b.shape or a.shape!=(len(begin),4):
        raise ValueError('complete one-dimensional state/residual shape required')
    if not all(np.isfinite(x).all() for x in [begin,end,a,b]):raise ValueError('nonfinite state')
    raw=[];paired=[]
    for component in range(3):
        raw.append(math.fsum(float(y)-float(x) for x,y in zip(begin[:,component],end[:,component]))*dx)
        if component==1:paired.append(raw[-1]);continue
        slot=0 if component==0 else 1
        # Sum differences as separate terms, before cancellation against the background total.
        paired.append(math.fsum(z for x,y,ex,ey in zip(begin[:,component],end[:,component],a[:,slot],b[:,slot]) for z in [float(y),-float(x),-float(ey),float(ex)])*dx)
    return dict(rawChange=raw,residualCorrectedChange=paired,units=['kg/m^2','Pa s','J/m^2'],normalization='unit transverse area',
        interpretation='Changes from exact Float32 dyadic components, accumulated with fsum before background cancellation. Not a physical dissipation budget; pressure-pair projection is not consumed GPU pressure.')


if __name__=='__main__':
    initial=np.array([[1.225,0,253314.546875]],dtype=np.float32)
    residual=np.array([[0,0,3,0]],dtype=np.float32).view(np.uint32)
    changed=residual.copy();changed.view(np.float32)[0,1]=2**-30
    r=conserved_changes(initial,initial,residual,changed,1.)
    assert r['rawChange']==[0.,0.,0.]
    assert r['residualCorrectedChange']==[0.,0.,-2**-30]
    # An even smaller retained low part disappears in a naive Double effective-state subtraction.
    changed.view(np.float32)[0,1]=2**-40
    r=conserved_changes(initial,initial,residual,changed,1.)
    assert float(initial[0,2])-float(changed.view(np.float32)[0,1])==float(initial[0,2])
    assert r['residualCorrectedChange'][2]==-2**-40
    print('Conserved-change controls retain low parts that naive background subtraction loses; no wave execution')
