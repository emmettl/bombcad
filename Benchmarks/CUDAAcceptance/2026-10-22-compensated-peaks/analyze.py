"""All-outcome saved-history pressure decomposition; never launches a numerical producer."""
import argparse
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path
import shutil
import sys
import numpy as np


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def extrema(values):
    return dict(minimum=float(np.min(values)),maximum=float(np.max(values)),
                maximumAbsolute=float(np.max(np.abs(values))))


def decompose(native,stored,pair,clock,reference,physical):
    arrays=[np.asarray(x,dtype=np.float64) for x in [native,stored,pair,clock,reference,physical]]
    native,stored,pair,clock,reference,physical=arrays
    if any(x.ndim!=1 or not np.isfinite(x).all() for x in arrays):raise ValueError('finite one-dimensional inputs required')
    if not(len(native)==len(stored)==len(pair)==len(clock)) or len(reference)!=len(physical) or min(len(clock),len(physical))<2:raise ValueError('paired nonempty histories required')
    if not np.all(np.diff(clock)>0) or not np.all(np.diff(physical)>0):raise ValueError('strictly increasing axes required')
    covered=(clock>=physical[0])&(clock<=physical[-1])
    if not np.any(covered):raise ValueError('no common physical-time coverage')
    indices=np.flatnonzero(covered);t=clock[covered];n=native[covered];s=stored[covered];p=pair[covered]
    aligned=np.interp(t,physical,reference)
    terms=np.column_stack([n-s,s-p,p-aligned]);total=n-aligned
    closure=np.fromiter((math.fsum(map(float,row))-float(value) for row,value in zip(terms,total)),dtype=np.float64,count=len(t))
    raw_peak=max(0.,float(np.max(reference)));aligned_peak=max(0.,float(np.max(aligned)))
    native_peak=max(0.,float(np.max(native)));maxima=np.flatnonzero(native==native_peak)
    positions=np.flatnonzero(n==native_peak)
    raw_maxima=np.flatnonzero(reference==raw_peak)
    def peak_info(values,axis):
        peak=max(0.,float(np.max(values)));at=np.flatnonzero(values==peak)
        return dict(peakPa=peak,maximumSampleIndices=at.tolist(),maximumTimesS=axis[at].tolist())
    at_peak=None
    if len(positions):
        point_terms=np.column_stack([terms[positions],aligned[positions]-raw_peak])
        first=int(positions[0]);at_peak=dict(sampleIndices=indices[positions].tolist(),timesS=t[positions].tolist(),
            terms=[extrema(point_terms[:,i]) for i in range(4)],
            termOrder=['nativeMinusStoredDoublePa','storedMinusPairDoublePa','pairMinusAlignedFloat64Pa','alignedAtNativePeakMinusRawFloat64PeakPa'],
            nativePeakMinusRawFloat64PeakPa=native_peak-raw_peak,
            first=dict(sampleIndex=int(indices[first]),timeS=float(t[first]),nativePa=float(n[first]),storedDoublePa=float(s[first]),pairDoublePa=float(p[first]),alignedFloat64Pa=float(aligned[first]),rawFloat64PeakPa=raw_peak,termsPa=point_terms[0].tolist()),
            maximumAbsoluteFourTermClosureResidualPa=max(abs(math.fsum(map(float,row))-(native_peak-raw_peak)) for row in point_terms))
    result=dict(coverageSamples=len(indices),totalNativeSamples=len(clock),uncoveredNativeMaximumIndices=[int(i) for i in maxima if not covered[i]],
        native=peak_info(native,clock),storedDouble=peak_info(stored,clock),pairDouble=peak_info(pair,clock),
        independentFloat64=peak_info(reference,physical),interpolatedFloat64PeakPa=aligned_peak,
        interpolationPeakMinusRawPeakPa=aligned_peak-raw_peak,
        fullCoverageTerms=[extrema(terms[:,i]) for i in range(3)],nativeMinusAlignedFloat64Pa=extrema(total),
        maximumAbsoluteThreeTermClosureResidualPa=float(np.max(np.abs(closure))),atNativeMaximum=at_peak)
    return result,dict(nativeIndices=indices,clock=t,alignedFloat64=aligned,terms=terms,nativeMinusAlignedFloat64=total)


def main(parent,root):
    parent=Path(parent).resolve();root=Path(root).resolve();here=Path(__file__).resolve().parent
    parent_inventory=json.loads((parent/'archive.json').read_text())['allRawFiles'];consumed={}
    def verify(name):
        path=parent/name;pin=parent_inventory[name]
        if name not in consumed:
            assert path.stat().st_size==pin['bytes'] and sha(path)==pin['sha256'],name
            consumed[name]=pin
        return path
    final=json.loads(verify('audit-v2/final.json').read_text());run=json.loads(verify('run.json').read_text())
    assert final['status']=='complete-all-outcome-audit' and len(final['rows'])==432 and final['allOraclesAvailable']
    assert run['status']=='complete' and 'liveProcess' not in run
    for pin in run['environment']['runtimeBytePins']:
        assert sha(pin['original'])==sha(pin['snapshot'])==pin['sha256']
    root.mkdir(parents=True,exist_ok=False);(root/'sources').mkdir();(root/'derived').mkdir()
    frozen={}
    for name in ['analyze.py','plan.md','check.py']:
        shutil.copyfile(here/name,root/'sources'/name);frozen[name]=sha(root/'sources'/name)
    context=dict(status='running',parentRoot=str(parent),parentArchiveReceiptSHA256=sha(parent/'archive.json'),
        parentPublication='17f7b57d260af3048318430979f28a53fb148c3f',frozenSourcesSHA256=frozen,
        python=sys.executable,pythonVersion=sys.version,numpyVersion=np.__version__,runtimeBytePins=run['environment']['runtimeBytePins'])
    (root/'context.json').write_text(json.dumps(context,indent=2)+'\n')
    @lru_cache(maxsize=4)
    def oracle(key):
        with np.load(verify('audit-v2/oracles/'+key+'.npz'),allow_pickle=False) as data:
            return {name:data[name].copy() for name in ['pressure','recordedClock','timestepSumTime','indices','dt']}
    rows=[]
    try:
        for case in final['rows']:
            job=case['job'];label=case['label'];row=dict(label=label,job=job,status='analysis-failed',columns=[])
            try:
                assert case['status']=='audited' and case['eligibleAsCandidateObservation'] and case['oracleStatus']=='complete'
                native=json.loads(verify('cases/'+label+'/'+job['case']+'-update-pressure-trace.json').read_text())
                values=np.asarray(native['values'],dtype=np.float32);clock=np.asarray(native['times'],dtype=np.float64)
                ref=oracle(case['oracleKey']);assert np.array_equal(clock,ref['recordedClock'])
                assert np.array_equal(np.asarray(native['columns']),ref['indices'])
                assert np.array_equal(np.r_[0.,np.cumsum(ref['dt'].astype(np.float64))],ref['timestepSumTime'])
                with np.load(verify('audit-v2/readouts/'+label+'.npz'),allow_pickle=False) as data:
                    assert np.array_equal(clock,data['clock']);selected=data['indices'].tolist()
                    derived={}
                    for q,column in enumerate(case['columns']):
                        index=selected.index(column['column']);metrics,arrays=decompose(values[:,q,0],data['storedDouble'][:,index],data['pairDouble'][:,index],clock,ref['pressure'][:,q],ref['timestepSumTime'])
                        assert metrics['native']['peakPa']==column['native']['peak'] and metrics['independentFloat64']['peakPa']==column['independentFloat64']['peak']
                        metrics.update(column=column['column'],x=column['x'],analyticPeakPa=column['native']['analyticPeak'],
                            nativeClosingSample=column['native']['streamingDouble']['closingSample'],referenceClosingSample=column['independentFloat64']['streaming']['closingSample'],
                            maximumAbsoluteDtSumMinusTickClockS=float(np.max(np.abs(ref['timestepSumTime']-clock))))
                        row['columns'].append(metrics)
                        for name,values_ in arrays.items():derived[f'column{q}_{name}']=values_
                    np.savez_compressed(root/'derived'/(label+'.npz'),**derived)
                row['status']='complete'
            except Exception as error:row['error']=repr(error)
            rows.append(row)
        assert len(rows)==432
        for name,pin in consumed.items():assert sha(parent/name)==pin['sha256'],name
        assert all(sha(root/'sources'/name)==pin for name,pin in frozen.items())
        for pin in context['runtimeBytePins']:assert sha(pin['original'])==sha(pin['snapshot'])==pin['sha256']
        context.update(status='complete' if all(r['status']=='complete' for r in rows) else 'complete-with-failures',consumedInputFiles=consumed)
        report=dict(status=context['status'],caseGroups=432,receiverHistories=sum(len(r['columns']) for r in rows),rows=rows,
            limits='Every planned outcome retained; pressure projections are counterfactual. Independent-model discrepancy is not a primitive/limiter/flux attribution. No numerical producer/reference rerun or admission/default change.')
        (root/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    except BaseException as error:context.update(status='failed',error=repr(error));raise
    finally:(root/'context.json').write_text(json.dumps(context,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='rows'},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('parent');parser.add_argument('root');args=parser.parse_args();main(args.parent,args.root)
