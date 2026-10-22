"""Merge all case outcomes and oracle comparisons; no new GPU work or target changes."""
import hashlib
import json
from pathlib import Path
import sys
import numpy as np
import phase


def main(audit_dir):
    audit_dir=Path(audit_dir);audit=json.loads((audit_dir/'audit.json').read_text());run=json.loads((audit_dir/'oracle-run.json').read_text())
    assert run['status'] in ['complete','complete-with-failures'] and all(j['terminal'] for j in run['jobs'])
    jobs={j['key']:j for j in run['jobs']}
    for row in audit['rows']:
        if row['status']!='audited':continue
        job=jobs[row['oracleKey']]
        for name,pin in job['retainedFiles'].items():
            path=audit_dir/'oracles'/name
            assert hashlib.sha256(path.read_bytes()).hexdigest()==pin['sha256']
        if job['returncode']!=0:row['oracleStatus']='failed';continue
        key=row['oracleKey'];meta=json.loads((audit_dir/'oracles'/(key+'.json')).read_text())
        with np.load(audit_dir/'oracles'/(key+'.npz'),allow_pickle=False) as data:
            pressure=data['pressure'];dt=np.r_[0.,data['dt'].astype(np.float64)];clock=data['recordedClock'];physical=data['timestepSumTime']
            assert np.all(np.diff(physical)>0) and len(clock)==len(physical)==len(pressure)
            with np.load(audit_dir/'readouts'/(row['label']+'.npz'),allow_pickle=False) as raw:
                assert np.array_equal(raw['clock'],clock)
                for q,column in enumerate(row['columns']):
                    p=pressure[:,q].tolist();w=dt.tolist();offline=phase.whole(p,w);stream=phase.streaming(p,w)
                    index=raw['indices'].tolist().index(column['column'])
                    covered=(clock>=physical[0])&(clock<=physical[-1])
                    aligned=np.interp(clock[covered],physical,pressure[:,q])
                    column['independentFloat64']=dict(offline=offline,streaming=stream,peak=offline['peak'],peakRelativeError=offline['peak']/column['native']['analyticPeak']-1,streamingImpulseRelativeError=stream['impulse']/column['native']['analyticFirstImpulse']-1,
                        storedDoublePressureLinfAtMatchedTimesteps=float(np.max(np.abs(raw['storedDouble'][:,index]-pressure[:,q]))),
                        pairDoublePressureLinfAtMatchedTimesteps=float(np.max(np.abs(raw['pairDouble'][:,index]-pressure[:,q]))),
                        storedDoublePressureLinfAtInterpolatedRecordedClock=float(np.max(np.abs(raw['storedDouble'][covered,index]-aligned))),
                        referenceTimeCoverageSamples=int(np.count_nonzero(covered)),totalSamples=len(clock),
                        timeScope='Identical retained Float32 dt sequence; both dt-sum and recorded-clock axes retained. Linear interpolation only inside reference coverage, no endpoint extrapolation. Pair pressure is a Double projection counterfactual, not consumed GPU pressure.')
        row['oracleStatus']='complete';row['independentModel']=meta
    audit['status']='complete-all-outcome-audit'
    audit['allOraclesAvailable']=all(r.get('oracleStatus')=='complete' for r in audit['rows'])
    audit['scientificCompletionScope']='Every planned case outcome retained. Completed audit is not dataset admission or default adoption; observation/floor/producer/oracle failures remain explicit.'
    destination=audit_dir/'final.json';assert not destination.exists();destination.write_text(json.dumps(audit,indent=2)+'\n')
    print(json.dumps({k:v for k,v in audit.items() if k not in ['rows','tiledFullPairs']},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
