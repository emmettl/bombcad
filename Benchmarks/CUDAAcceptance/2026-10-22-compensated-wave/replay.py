"""Draft pure replay helper. No numerical wave execution and no output-file writes."""
import ctypes
import math
import numpy as np

_lib=ctypes.CDLL(None)
_fma=_lib.fmaf
_fma.argtypes=[ctypes.c_float]*3
_fma.restype=ctypes.c_float


def words(value):
    array=np.asarray(value)
    if array.dtype.kind not in 'iu' or array.size==0 or array.min()<0 or array.max()>0xffffffff:
        raise ValueError('canonical uint32 words required')
    return array.astype(np.uint32)


def audit(trace, initial_residual_words, final_residual_words):
    raw=words(trace['valueBits']);v=raw.view(np.float32)
    active=np.asarray(trace['executed'])
    if active.dtype!=np.bool_:raise ValueError('execution flags must be booleans')
    initial=words(trace['initialStateBits']);final=words(trace['finalStateBits'])
    indices=trace['indices'];n=len(trace['steps']);m=len(indices)
    if raw.shape!=(n,m,33) or active.shape!=(n,m) or initial.shape!=final.shape or initial.shape!=(m,5):
        raise ValueError('trace shape mismatch')
    if not np.isfinite(v).all():raise ValueError('nonfinite captured value')
    if trace['steps']!=list(range(1,n+1)):raise ValueError('missing active step')
    begin=words(initial_residual_words);end=words(final_residual_words)
    if begin.shape!=end.shape or begin.ndim!=2 or begin.shape[1]!=4:raise ValueError('residual shape mismatch')
    state=initial.copy();error=begin[indices,:2].copy();floor=begin[indices,3].copy()
    state_discontinuities=residual_discontinuities=floor_discontinuities=0
    for i in range(n):
        yes=active[i]
        if np.any(raw[i,~yes]!=0):raise ValueError('skipped slot contains fabricated/stale values')
        state_discontinuities+=int(np.count_nonzero(raw[i,yes,:5]!=state[yes]))
        residual_discontinuities+=int(np.count_nonzero(raw[i,yes,24:26]!=error[yes]))
        floor_discontinuities+=int(np.count_nonzero(raw[i,yes,29]!=floor[yes]))
        state[yes]=raw[i,yes,5:10];error[yes]=raw[i,yes,26:28];floor[yes]=raw[i,yes,30]
    values=v[active];bits=raw[active]
    if not len(values):raise ValueError('no selected executed observations')
    masks=values[:,28].astype(np.uint32)
    if not np.all(values[:,28]==masks) or not np.all(np.isin(masks,[1,2,3,5,6,7])):
        raise ValueError('invalid component/carry mask')
    if not np.all(masks==masks[0]):raise ValueError('method changes inside trace')
    mask=int(masks[0]);discard=bool(mask&4)
    begin_values=begin.view(np.float32);end_values=end.view(np.float32)
    if not np.isfinite(begin_values).all() or not np.isfinite(end_values).all():raise ValueError('nonfinite residual state')
    if not np.all(begin_values[:,2]==mask) or not np.all(end_values[:,2]==mask):raise ValueError('global method mask mismatch')
    counts=end_values[:,3]-begin_values[:,3]
    if not np.all(counts>=0) or not np.all(counts==np.floor(counts)):raise ValueError('floor counters must be monotone exact integers')
    total_floor_events=int(np.sum(counts,dtype=np.float64))
    affected=values[:,30]!=values[:,29]
    differences=values[:,15:20]-values[:,10:15]
    ordinary_separate=values[:,:5]-values[:,20,None]*differences
    ordinary_fused=np.fromiter((_fma(-float(l),float(d),float(old)) for l,row,oldrow in zip(values[:,20],differences,values[:,:5]) for d,old in zip(row,oldrow)),dtype=np.float32,count=len(values)*5).reshape(-1,5)
    selected=[index for bit,index in [(1,0),(2,4)] if mask&bit]
    ordinary_indices=[i for i in range(5) if i not in selected]
    ordinary={name:int(np.count_nonzero(candidate[:,ordinary_indices].view(np.uint32)!=bits[:,np.array(ordinary_indices)+5])) for name,candidate in [('separate',ordinary_separate),('fused',ordinary_fused)]}
    components=[]
    for bit,old,new,lo,hi,old_error,new_error,increment in [(1,0,5,10,15,24,26,31),(2,4,9,14,19,25,27,32)]:
        if not mask&bit:continue
        delta=-values[:,20]*(values[:,hi]-values[:,lo])
        corrected=delta-values[:,old_error]
        expected=values[:,old]+corrected
        expected_error=(expected-values[:,old])-corrected
        if discard:expected_error=np.zeros_like(expected_error)
        # Floors are retained explicitly; no claim that post-floor state is an unfloored update.
        known=~affected
        remainders=np.fromiter((math.fsum([float(b),-float(a),-float(eb),float(ea),-float(d)]) for a,b,ea,eb,d in zip(values[:,old],values[:,new],values[:,old_error],values[:,new_error],values[:,increment])),dtype=np.float64,count=len(values))
        components.append(dict(component='density' if bit==1 else 'energy',
            incrementWordDifferences=int(np.count_nonzero(delta.view(np.uint32)!=bits[:,increment])),
            noFloorStateWordDifferences=int(np.count_nonzero(expected[known].view(np.uint32)!=bits[known,new])),
            noFloorResidualWordDifferences=int(np.count_nonzero(expected_error[known].view(np.uint32)!=bits[known,new_error])),
            exactPairIncrementRemainderNonzero=int(np.count_nonzero(remainders)),
            sumAbsolutePairIncrementRemainder=float(np.sum(np.abs(remainders),dtype=np.float64))))
    return dict(componentMask=mask,discardResiduals=discard,prePostStateDiscontinuities=state_discontinuities,
        prePostResidualDiscontinuities=residual_discontinuities,prePostFloorDiscontinuities=floor_discontinuities,
        finalStateMatches=bool(np.array_equal(state,final)),
        finalResidualMatches=bool(np.array_equal(error,end[indices,:2])),
        finalFloorCountsMatch=bool(np.array_equal(floor,end[indices,3])),
        floorAffectedSelectedUpdates=int(np.count_nonzero(affected)),
        totalFloorEvents=total_floor_events,
        strictNoFloorReplay=total_floor_events==0 and not np.any(affected) and all(not c['incrementWordDifferences'] and not c['noFloorStateWordDifferences'] and not c['noFloorResidualWordDifferences'] for c in components),
        ordinaryModelDifferences=ordinary,ordinaryWholeTracePolicies=[k for k,v in ordinary.items() if v==0],components=components,
        limits='Selected cells, arithmetic compatibility not instructions; floor-affected operations retained but not attested by the unfloored replay. Exact pair increments use fsum before background cancellation, not two rounded effective-state readouts.')
