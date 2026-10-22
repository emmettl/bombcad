"""Canonical host-source validation and conditional local-model comparisons."""
import hashlib
import numpy as np
from components import operator,mapped_state


def words(value):
    x=np.asarray(value)
    if x.dtype.kind not in 'iu' or not x.size or x.min()<0 or x.max()>0xffffffff:raise ValueError('canonical uint32 source words required')
    return x.astype(np.uint32)


def validate(source,updates,snapshot,nx):
    assert source['format']=='bombcad-compensated-source-stencil-1' and source['sourceObservation']=='host-physical-cells-before-blocking-part'
    assert source['sourceConservedFields']==['rho','mx','my','mz','energy'] and source['sourceResidualFields']==['rhoError','energyError','mask','floorEvents']
    for key in ['fields','valueEncoding','indices','steps','times','dt','executed','valueBits','initialStateBits','finalStateBits']:assert source[key]==updates[key],key
    assert source['valueEncoding']=='uint32-ieee754-binary32' and len(source['fields'])==33
    state=words(source['sourceConservedBits']);residual=words(source['sourceResidualBits']);raw=words(source['valueBits'])
    active=np.asarray(source['executed']);n=len(source['steps']);m=len(source['indices'])
    assert active.dtype==np.bool_ and active.shape==(n,m) and raw.shape==(n,m,33)
    assert state.shape==(n,m,5,5) and residual.shape==(n,m,5,4)
    assert source['steps']==list(range(1,n+1)) and np.isfinite(state.view(np.float32)).all() and np.isfinite(residual.view(np.float32)).all()
    physical=np.asarray(source['sourcePhysicalIndices']);signs=np.asarray(source['sourceGhostVelocitySigns'])
    expected=[];mirrors=[]
    for i in source['indices']:
        expected.append([(-j-1 if j<0 else min(j,nx-1)) for j in range(i-2,i+3)])
        mirrors.append([-1 if j<0 else 1 for j in range(i-2,i+3)])
    assert np.array_equal(physical,expected) and np.array_equal(signs,mirrors)
    initial=np.asarray(snapshot['initialConservedRhoMxEnergy'],dtype=np.float32)
    full=np.zeros((nx,5),dtype=np.float32);full[:,[0,1,4]]=initial
    initial_residual=words(snapshot['initialResidualBits'])
    assert np.array_equal(state[0],full.view(np.uint32)[physical]) and np.array_equal(residual[0],initial_residual[physical])
    held=words(updates['initialStateBits']).copy();errors=initial_residual[source['indices']].copy()
    for i in range(n):
        assert np.array_equal(state[i,:,2],held) and np.array_equal(residual[i,:,2],errors)
        yes=active[i];held[yes]=raw[i,yes,5:10];errors[yes]=raw[i,yes][:,[26,27,28,30]]
    assert np.array_equal(held,words(updates['finalStateBits']))
    assert np.array_equal(errors,words(snapshot['finalResidualBits'])[source['indices']])
    # Duplicate physical sources must be identical even when their ghost transformations differ.
    flat=physical.ravel();s=state.reshape(n,-1,5);e=residual.reshape(n,-1,4)
    for index in np.unique(flat):
        at=np.flatnonzero(flat==index)
        assert np.all(s[:,at]==s[:,at[:1]]) and np.all(e[:,at]==e[:,at[:1]])
    cfg={k:float(np.float32(v)) for k,v in source['sourceConfiguration'].items()}
    assert cfg['gamma']==float(np.float32(snapshot['gamma'])) and cfg['dx']==float(np.float32(16/nx))
    assert cfg['limiterTheta']==1.5 and cfg['densityFloor']==float(np.float32(1e-6)) and cfg['pressureFloor']==float(np.float32(1e-3))
    v=raw.view(np.float32);dt=np.asarray(source['dt'],dtype=np.float32)
    assert np.all(v[...,21][active]==np.broadcast_to(dt[:,None],(n,m))[active])
    assert np.array_equal(v[...,20][active],(np.broadcast_to(dt[:,None],(n,m))/np.float32(cfg['dx']))[active])
    return dict(state=state,residual=residual,raw=raw,active=active,physical=physical,signs=signs,configuration=cfg)


def analyze(engine,validated,output):
    d=validated;yes=d['active'];cfg=d['configuration'];raw=d['raw'].view(np.float32)
    stored=mapped_state(d['state'],d['residual'],d['signs']);paired=mapped_state(d['state'],d['residual'],d['signs'],paired=True)
    selected=stored[yes];pair=paired[yes];lam=raw[...,20][yes]
    actual=np.stack([raw[...,[10,11,14]],raw[...,[15,16,19]]],axis=-2)[yes]
    conditional_delta=-lam.astype(np.float64)[:,None]*(actual[:,1].astype(np.float64)-actual[:,0].astype(np.float64))
    model_specs=[('stored64',selected,None),('pair64',pair,None),('separate32',selected.astype(np.float32),None),
                 ('roundedPrimitive64',selected,'primitive'),('roundedSlope64',selected,'slope'),('roundedFaces64',selected,'faces')]
    arrays=dict(executedSampleAndColumn=np.argwhere(yes),actualCapturedFlux=actual,conditionalCapturedFluxDelta=conditional_delta)
    summaries=[]
    for name,state,rounded in model_specs:
        result=operator(engine,state,lam,cfg['gamma'],cfg['limiterTheta'],cfg['densityFloor'],cfg['pressureFloor'],rounded)
        flux=result['flux'];difference=flux[:,1].astype(np.float64)-flux[:,0].astype(np.float64)
        native_difference=actual[:,1].astype(np.float64)-actual[:,0].astype(np.float64)
        nonzero=difference!=0;equal=(native_difference==0)&nonzero
        summary=dict(model=name,reconstructionFallbacks=int(np.count_nonzero(result['fallback'])),
            maximumAbsoluteFluxDifferenceByFaceAndComponent=np.max(np.abs(flux.astype(np.float64)-actual.astype(np.float64)),axis=0).tolist(),
            maximumAbsoluteFluxDifferenceErrorByComponent=np.max(np.abs(difference-native_difference),axis=0).tolist(),
            maximumAbsoluteConditionalDeltaErrorByComponent=np.max(np.abs(result['delta'].astype(np.float64)-conditional_delta),axis=0).tolist(),
            nonzeroModelFaceDifferenceCount=np.count_nonzero(nonzero,axis=0).tolist(),equalNativeFacesForNonzeroModelDifference=np.count_nonzero(equal,axis=0).tolist(),
            sumAbsoluteConditionalDeltaWhereNativeFacesEqual=np.sum(np.where(equal,np.abs(result['delta']),0),axis=0,dtype=np.float64).tolist())
        if flux.dtype==np.float32:summary['wholeTraceCapturedFluxWordDifferences']=int(np.count_nonzero(flux.view(np.uint32)!=actual.view(np.uint32)))
        summaries.append(summary)
        for key,value in result.items():arrays[name+'_'+key]=value
    np.savez_compressed(output,**arrays)
    return dict(executedOpportunities=int(np.count_nonzero(yes)),skippedOpportunities=int(np.count_nonzero(~yes)),models=summaries,
        capturedFluxFloat32SpacingMinimumByFaceAndComponent=np.min(np.abs(np.spacing(actual)).astype(np.float64),axis=0).tolist(),
        capturedFluxFloat32SpacingMaximumByFaceAndComponent=np.max(np.abs(np.spacing(actual)).astype(np.float64),axis=0).tolist(),
        sourceHistorySHA256=hashlib.sha256(d['state'].tobytes()+d['residual'].tobytes()).hexdigest(),
        limits='All model stages recomputed from observed conserved inputs, not observed GPU intermediates. Flux/delta errors and zero-difference counts are conditional comparisons, not physical dissipation or an independently evolved PDE solution. Separate32 compatibility is whole trace, never selected per scalar.')
