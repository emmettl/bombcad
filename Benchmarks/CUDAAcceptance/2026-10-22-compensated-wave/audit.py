"""All-outcome compensated-wave audit. Never reruns GPU cases or changes target definitions."""
import argparse
import array
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import numpy as np
import phase
import readouts
import replay

FIELDS=['oldRho','oldMx','oldMy','oldMz','oldEnergy','newRho','newMx','newMy','newMz','newEnergy','lowMass','lowMx','lowMy','lowMz','lowEnergy','highMass','highMx','highMy','highMz','highEnergy','lambda','dt','axis','batchActiveStep','oldResidualRho','oldResidualEnergy','newResidualRho','newResidualEnergy','componentMask','floorEventsBefore','floorEventsAfter','densityIncrement','energyIncrement']
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'cuda'))

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


def load(path):return json.loads(Path(path).read_text())
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def column(pressure,dt,peak,impulse):
    offline=phase.whole(pressure,dt);stream=phase.streaming(pressure,dt)
    return dict(offline=offline,streamingDouble=stream,peak=offline['peak'],
        peakRelativeError=offline['peak']/peak-1,streamingImpulseRelativeError=stream['impulse']/impulse-1,
        analyticPeak=peak,analyticFirstImpulse=impulse,
        semanticDifference=offline['impulse']!=stream['impulse'] or offline['closingSample']!=stream['closingSample'])


def case(root,output,job,baseline,diagnose):
    name=job['case'];folder=root/'cases'/job['label'];nx=job['nx']
    snapshots=[load(folder/(name+'-'+mode+'.json')) for mode in ['plain','observed','updates']]
    observed=load(folder/(name+'-trace.json'));pressure=load(folder/(name+'-update-pressure-trace.json'))
    trace=load(folder/(name+'-update-trace.json'))
    assert trace['format']=='bombcad-compensated-sweep-updates-1' and trace['valueEncoding']=='uint32-ieee754-binary32'
    assert trace['indices']==[0,nx//4,nx//2-1,nx//2,nx//2+1,nx-1]
    assert trace['fields']==FIELDS
    for row in [*snapshots,observed,pressure,trace]:
        assert row['experimentalMethod']==job['method'] and row['compensationComponents']==job['components']
    assert all(x['stable'] for x in snapshots) and observed['complete'] and pressure['complete'] and trace['complete']
    keys=['steps','time','initialHashes','finalHashes','records','initialConservedRhoMxEnergy','initialHostProjectedOverpressurePa','initialResidualBits','finalResidualBits','finalConservedRhoMxEnergy']
    parity={k:all(snapshots[0][k]==s[k] for s in snapshots[1:]) for k in keys}
    pressure_equal=sha(folder/(name+'-trace.json'))==sha(folder/(name+'-update-pressure-trace.json'))
    old_folder=Path(baseline['root'])/(job['policy']+'-cfl'+job['cfl'])
    previous=old_folder/(name+'-plain.json');pin=baseline['receipt']['retainedFiles'][str(previous.relative_to(Path(baseline['root'])))]
    assert sha(previous)==pin['sha256'];old=load(previous)
    initial_keys=['initialConservedRhoMxEnergy','initialHostProjectedOverpressurePa','gamma','cfl']
    initial_parity={k:snapshots[0][k]==old[k] for k in initial_keys}
    initial_parity['ordinaryInitialHashes']=all(snapshots[0]['initialHashes'][k]==value for k,value in old['initialHashes'].items())
    n=snapshots[2]['steps'];assert trace['steps']==list(range(1,n+1))
    assert pressure['steps']==list(range(n+1)) and trace['times']==pressure['times'][1:]
    assert pressure['times'][0]==0 and pressure['times'][-1]==snapshots[2]['time']
    assert all(b>a for a,b in zip(pressure['times'],pressure['times'][1:]))
    assert pressure['times'][-1]>=14/pressure['soundSpeed']*(1-1e-6)
    values=np.asarray(pressure['values'],dtype=np.float32)
    assert values.shape==(n+1,2,8) and np.isfinite(values).all()
    dt=np.asarray(trace['dt'],dtype=np.float32)
    assert dt.shape==(n,) and np.all(dt>0) and np.array_equal(values[1:,:,6],np.broadcast_to(dt[:,None],(n,2))) and np.all(values[0,:,6]==0)
    expected_mask={'density':1,'energy':2,'both':3}[job['components']] + (4 if job['method']=='protected-update-no-carry-v1' else 0)
    mechanics=replay.audit(trace,snapshots[2]['initialResidualBits'],snapshots[2]['finalResidualBits'])
    assert mechanics['componentMask']==expected_mask
    meta=dict(format='bombcad-production-pressure-trace-1',columns=pressure['columns'],times=pressure['times'],seedRecords=[[diagnose.f32(x) for x in row] for row in pressure['seedRecords']],fields=diagnose.FIELDS)
    recorder=diagnose.summarize(meta,array.array('f',values.ravel().tolist()))
    gamma=float(np.float32(snapshots[2]['gamma']));dx=float(np.float32(pressure['dx']))
    stored,paired=readouts.history(trace,snapshots[2]['initialResidualBits'],gamma)
    clocks=np.asarray(pressure['times'],dtype=np.float64);weights=np.r_[0.,dt.astype(np.float64)]
    records=[]
    for q,index in enumerate(pressure['columns']):
        selected=trace['indices'].index(index)
        args=[float(pressure['analyticPeak'][q]),float(pressure['analyticFirstImpulse'][q])]
        records.append(dict(column=index,x=pressure['x'][q],native=column(values[:,q,0].astype(float).tolist(),weights.tolist(),*args),
            storedDouble=column(stored[:,selected].tolist(),weights.tolist(),*args),
            pairDoubleCounterfactual=column(paired[:,selected].tolist(),weights.tolist(),*args),
            nativeRecorderFirstImpulse=float(values[-1,q,3]),finalOpen=bool(values[-1,q,5]),
            exactRecorderReplayPolicies=recorder['columns'][q]['exactAccumulationPolicies']))
    conservation=readouts.conserved_changes(snapshots[2]['initialConservedRhoMxEnergy'],snapshots[2]['finalConservedRhoMxEnergy'],snapshots[2]['initialResidualBits'],snapshots[2]['finalResidualBits'],dx)
    raw=np.asarray(trace['valueBits'],dtype=np.uint32).view(np.float32);active=np.asarray(trace['executed'],dtype=bool)
    boundary_complete=bool(np.all(active[:,[0,-1]]))
    conservation['bothBoundariesObservedAtEveryStep']=boundary_complete
    if boundary_complete:
        integral=[math.fsum(float(width)*(float(high)-float(low)) for width,high,low in zip(dt,raw[:,-1,15+k],raw[:,0,10+k])) for k in [0,1,4]]
        conservation['boundaryFluxIntegral']=integral
        conservation['rawBoundaryBalancedResidual']=[a+b for a,b in zip(conservation['rawChange'],integral)]
        conservation['pairBoundaryBalancedResidual']=[a+b for a,b in zip(conservation['residualCorrectedChange'],integral)]
    else:conservation['boundaryBudgetUnavailable']='Skipped opportunities are not observations; no fabricated boundary flux.'
    initial=np.asarray(snapshots[2]['initialConservedRhoMxEnergy'],dtype=np.float32)
    indices=np.asarray(pressure['columns'],dtype=np.int64)
    digest=hashlib.sha256()
    for data in [initial,dt,clocks,indices,np.asarray([gamma,dx],dtype=np.float64)]:digest.update(data.tobytes())
    key=digest.hexdigest();input_path=output/'oracle-inputs'/(key+'.npz')
    if not input_path.exists():np.savez_compressed(input_path,initial=initial,dt=dt,clock=clocks,indices=indices,gamma=np.array(gamma),dx=np.array(dx))
    np.savez_compressed(output/'readouts'/(job['label']+'.npz'),clock=clocks,dt=weights,storedDouble=stored,pairDouble=paired,indices=np.asarray(trace['indices']))
    strict=all(parity.values()) and all(initial_parity.values()) and pressure_equal and mechanics['strictNoFloorReplay'] and bool(mechanics['ordinaryWholeTracePolicies']) and mechanics['prePostStateDiscontinuities']==mechanics['prePostResidualDiscontinuities']==mechanics['prePostFloorDiscontinuities']==0 and mechanics['finalStateMatches'] and mechanics['finalResidualMatches'] and mechanics['finalFloorCountsMatch'] and all(r['exactRecorderReplayPolicies'] for r in records)
    return dict(label=job['label'],job=job,status='audited',eligibleAsCandidateObservation=bool(strict),observationParity=parity,initialBaselineParity=initial_parity,pressureTraceBytesIdentical=pressure_equal,mechanics=mechanics,columns=records,conservation=conservation,oracleKey=key,
        initialHashes=snapshots[2]['initialHashes'],finalHashes=snapshots[2]['finalHashes'],steps=n,time=snapshots[2]['time'],nativePressureTraceDataSHA256=hashlib.sha256(values.tobytes()+clocks.tobytes()+indices.tobytes()).hexdigest(),
        heldGPUBufferBytes=[x['heldGPUBufferBytes'] for x in snapshots],advanceWallSeconds=[x['advanceWallSeconds'] for x in snapshots],
        maximumAbsoluteDtSumMinusRecordedClockS=float(np.max(np.abs(np.r_[0.,np.cumsum(dt.astype(np.float64))]-clocks))))


def main(root,output):
    root=Path(root);output=Path(output);output.mkdir(parents=True,exist_ok=False)
    (output/'oracle-inputs').mkdir();(output/'readouts').mkdir()
    run=load(root/'run.json');assert run['status'] in ['complete','complete-with-failures'] and 'liveProcess' not in run
    assert len(run['commands'])==len(run['plan']['jobs'])==432 and len({j['label'] for j in run['plan']['jobs']})==432
    for pin in run['frozenSources']:assert sha(pin['path'])==pin['sha256']
    for name,pin in run['runtimeSHA256'].items():assert sha(root/'runtime'/name)==pin
    commands={j['label']:j for j in run['commands']};rows=[]
    baseline=load(HERE/'baseline.json');diagnose=module('diagnose',HERE/'cuda/diagnose-phase.py')
    for job in run['plan']['jobs']:
        command=commands[job['label']]
        assert 'terminalProcess' in command
        folder=root/'cases'/job['label']
        for name,pin in command['retainedFiles'].items():assert sha(folder/name)==pin['sha256'] and (folder/name).stat().st_size==pin['bytes']
        if command['returncode']!=0:
            rows.append(dict(label=job['label'],job=job,status='producer-failed',eligibleAsCandidateObservation=False,returncode=command['returncode']));continue
        try:rows.append(case(root,output,job,baseline,diagnose))
        except Exception as error:rows.append(dict(label=job['label'],job=job,status='audit-failed',eligibleAsCandidateObservation=False,error=repr(error)))
    lookup={r['label']:r for r in rows};pairs=[]
    for row in rows:
        if row['job']['tiled']:continue
        other=lookup[row['label'][:-4]+'tiled']
        same=row['status']==other['status']=='audited' and all(row[k]==other[k] for k in ['initialHashes','finalHashes','steps','time','nativePressureTraceDataSHA256'])
        pairs.append(dict(full=row['label'],tiled=other['label'],exactFinalStateResidualRecorderClockParity=bool(same)))
    report=dict(status='audited-awaiting-oracles',caseGroups=len(rows),expectedExports=1296,rows=rows,tiledFullPairs=pairs,
        allCandidateObservationGates=all(r['eligibleAsCandidateObservation'] for r in rows),allTiledFullFinalParity=all(p['exactFinalStateResidualRecorderClockParity'] for p in pairs),
        limits='All opportunities retained; parser/floor/observation failures are not discarded. Double pair pressure is an analysis counterfactual, not consumed pressure. Native phase rule/default/admission unchanged. Independent Float64 outputs still required; no completed experiment/adoption claim.')
    (output/'audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['rows','tiledFullPairs']},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root');parser.add_argument('output');args=parser.parse_args();main(args.root,args.output)
