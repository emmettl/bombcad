"""All-outcome four-mode/prior-wave/source/model audit. No numerical producer or oracle rerun."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import numpy as np

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'legacy'))


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


legacy=module('legacy_wave_audit',HERE/'legacy/audit-v2.py')
source_model=module('source_model',HERE/'source-audit.py')
sha=legacy.sha;load=legacy.load


def main(root,out):
    root=Path(root);out=Path(out);out.mkdir(exist_ok=False);(out/'oracle-inputs').mkdir();(out/'readouts').mkdir();(out/'components').mkdir()
    run=load(root/'run.json');assert run['status'] in ['complete','complete-with-failures'] and 'liveProcess' not in run
    assert len(run['commands'])==len(run['plan']['jobs'])==432
    assert len({j['label'] for j in run['plan']['jobs']})==len({c['label'] for c in run['commands']})==432
    for pin in run['frozenSources']:assert sha(pin['path'])==pin['sha256']
    for name,pin in run['runtimeSHA256'].items():assert sha(root/'runtime'/name)==pin
    for name,pin in run['analysisSHA256'].items():assert sha(HERE/name)==pin
    for pin in run['environment']['runtimeBytePins']:assert sha(pin['original'])==sha(pin['snapshot'])==pin['sha256']
    prior=load(HERE/'prior-wave.json');parent=Path(prior['root']);inventory=prior['inventory'];consumed={}
    def previous(name):
        path=parent/name;pin=inventory[name]
        if name not in consumed:assert sha(path)==pin['sha256'] and path.stat().st_size==pin['bytes'];consumed[name]=pin
        return path
    prior_final=load(previous('audit-v2/final.json'));old_rows={r['label']:r for r in prior_final['rows']}
    engine=module('independent_euler',HERE/'planar_euler.py');diagnose=legacy.module('diagnose',HERE/'legacy/cuda/diagnose-phase.py')
    commands={c['label']:c for c in run['commands']};baseline=load(HERE/'legacy/baseline.json');rows=[]
    snapshot_keys=['steps','time','initialHashes','finalHashes','records','initialConservedRhoMxEnergy','initialHostProjectedOverpressurePa','initialResidualBits','finalResidualBits','finalConservedRhoMxEnergy']
    for job in run['plan']['jobs']:
        label=job['label'];command=commands[label];assert 'terminalProcess' in command
        folder=root/'cases'/label;name=job['case'];row=dict(label=label,job=job,status='producer-failed',eligibleAsCandidateObservation=False)
        for file,pin in command['retainedFiles'].items():assert sha(folder/file)==pin['sha256'] and (folder/file).stat().st_size==pin['bytes']
        if command['returncode']:
            row['returncode']=command['returncode'];rows.append(row);continue
        try:
            row=legacy.case(root,out,job,baseline,diagnose)
            ordinary=load(folder/(name+'-updates.json'));host=load(folder/(name+'-sources.json'))
            fourth={k:ordinary[k]==host[k] for k in snapshot_keys};assert all(fourth.values()) and host['stable'] and host['hostSourceObserved']
            assert ordinary['heldGPUBufferBytes']==host['heldGPUBufferBytes']
            source=load(folder/(name+'-source-stencil.json'));updates=load(folder/(name+'-update-trace.json'))
            assert source['complete']
            assert sha(folder/(name+'-source-pressure-trace.json'))==sha(folder/(name+'-update-pressure-trace.json'))
            data=source_model.validate(source,updates,host,job['nx'])
            old=load(previous('cases/'+label+'/'+name+'-updates.json'))
            parity={k:ordinary[k]==old[k] for k in snapshot_keys}
            prior_update_bytes=sha(folder/(name+'-update-trace.json'))==sha(previous('cases/'+label+'/'+name+'-update-trace.json'))
            prior_pressure_bytes=sha(folder/(name+'-trace.json'))==sha(previous('cases/'+label+'/'+name+'-trace.json'))
            old_row=old_rows[label];reference_key_match=row['oracleKey']==old_row['oracleKey']
            if reference_key_match:
                row['independentModel']=old_row['independentModel'];row['oracleStatus']='reused-identical-input'
                for c,old_c in zip(row['columns'],old_row['columns']):assert c['column']==old_c['column'];c['independentFloat64']=old_c['independentFloat64']
            else:row['oracleStatus']='unavailable-different-input'
            metrics=source_model.analyze(engine,data,out/'components'/(label+'.npz'))
            with np.load(out/'readouts'/(label+'.npz'),allow_pickle=False) as readout:
                stored=source_model.mapped_state(data['state'],data['residual'],data['signs'])
                pre_pressure=engine.primitive(stored[...,2,:].reshape(-1,3),data['configuration']['gamma'])[:,2].reshape(len(source['steps']),-1)-101325
                assert np.array_equal(pre_pressure,readout['storedDouble'][:-1])
            row.update(status='audited',fourthObservationParity=fourth,priorWaveParity=parity,priorUpdateTraceBytesIdentical=prior_update_bytes,
                priorPressureBytesIdentical=prior_pressure_bytes,independentReferenceInputKeyMatches=reference_key_match,source=metrics,
                hostSourceHeldGPUBufferBytes=host['heldGPUBufferBytes'],hostSourceAdvanceWallSeconds=host['advanceWallSeconds'],sourcePreStepPressureAlignment=True)
            row['eligibleAsCandidateObservation']=row['eligibleAsCandidateObservation'] and all(parity.values()) and prior_update_bytes and prior_pressure_bytes and reference_key_match
        except Exception as error:row.update(status='audit-failed',eligibleAsCandidateObservation=False,error=repr(error))
        rows.append(row)
    lookup={r['label']:r for r in rows};pairs=[]
    for row in rows:
        if row['job']['tiled']:continue
        other=lookup[row['label'][:-4]+'tiled'];valid=row['status']==other['status']=='audited'
        same=valid and all(row[k]==other[k] for k in ['finalHashes','steps','time','nativePressureTraceDataSHA256'])
        sources=valid and row['source']['sourceHistorySHA256']==other['source']['sourceHistorySHA256']
        pairs.append(dict(full=row['label'],tiled=other['label'],finalStateResidualRecorderClockPressureParity=bool(same),entireHostSourceHistoryParity=bool(sources)))
    for name,pin in consumed.items():assert sha(parent/name)==pin['sha256']
    for name,pin in run['analysisSHA256'].items():assert sha(HERE/name)==pin
    for pin in run['environment']['runtimeBytePins']:assert sha(pin['original'])==sha(pin['snapshot'])==pin['sha256']
    report=dict(status='complete-all-outcome-source-audit',caseGroups=432,expectedExports=1728,rows=rows,tiledFullPairs=pairs,consumedPriorFiles=consumed,
        allObservationAndPriorGates=all(r['eligibleAsCandidateObservation'] for r in rows),allFullTiledFinalParity=all(p['finalStateResidualRecorderClockPressureParity'] for p in pairs),
        allFullTiledSourceHistories=all(p['entireHostSourceHistoryParity'] for p in pairs),
        limits='Every planned outcome retained. All component intermediates are recomputed conditional models; no GPU-intermediate/instruction attribution, physical dissipation or independently evolved PDE claim. Existing Float64 references reused only for identical input keys, not rerun. No default/admission change.')
    (out/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ['rows','tiledFullPairs','consumedPriorFiles']},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root');parser.add_argument('out');args=parser.parse_args();main(args.root,args.out)
