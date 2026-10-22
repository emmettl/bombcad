"""Enumerate every unchanged-gate failure in the three fixed-reference pilots."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main(root,output):
    root=Path(root);output=Path(output);queue=json.loads((root/'queued-cuda/run.json').read_text())
    assert queue['status']=='complete-all-outcomes' and len(queue['rows'])==3
    frozen=json.loads((root/'run.json').read_text())
    assert sha(root/'analysis/cuda/compare_dataset.py')==frozen['frozenFiles']['analysis/cuda/compare_dataset.py']['sha256']
    assert {r['id'] for r in queue['rows']}=={j['id'] for j in frozen['jobs']}
    spec=importlib.util.spec_from_file_location('frozen_compare',root/'analysis/cuda/compare_dataset.py');compare=importlib.util.module_from_spec(spec);spec.loader.exec_module(compare)
    source_hash=frozen['generatedSourceSHA256']
    old_path=Path(__file__).resolve().parents[1]/'2026-10-21-training-pilots.json'
    old=json.loads(old_path.read_text());old_rows={r['id']:r for r in old['cases']}
    consumed={str(old_path):sha(old_path),str(root/'queued-cuda/run.json'):sha(root/'queued-cuda/run.json'),str(root/'run.json'):sha(root/'run.json'),str(root/'analysis/cuda/compare_dataset.py'):sha(root/'analysis/cuda/compare_dataset.py')};rows=[]
    for result in queue['rows']:
        name=result['id'];row=dict(id=name,status=result['status'],eligible=False)
        if result['status']!='compared':row['unavailableReason']='CUDA worker did not complete';rows.append(row);continue
        ref=root/'cases'/name/'metal';candidate=root/'queued-cuda'/name/'dataset'
        for folder in [ref,candidate]:
            for file in ['inputs.npy','targets.npy','mask.npy','meta.json']:consumed[str(folder/file)]=sha(folder/file)
        scored=compare.compare(ref,candidate);assert scored==result['comparison']
        shape,a=compare.npy(ref/'targets.npy');other,b=compare.npy(candidate/'targets.npy');assert shape==other and len(shape)==3 and shape[0]==3
        mask_shape,mask=compare.npy(ref/'mask.npy');assert tuple(mask_shape)==tuple(shape[1:])
        plane=shape[1]*shape[2];failures=[];counts=[0]*shape[0]
        for channel in range(shape[0]):
            for index,valid in enumerate(mask):
                if not valid:continue
                x=float(a[channel*plane+index]);y=float(b[channel*plane+index]);error=abs(x-y);allowed=.05+.002*abs(x)
                if error>allowed:
                    counts[channel]+=1
                    failures.append(dict(channel=channel,index=index,row=index//shape[2],column=index%shape[2],reference=x,candidate=y,absoluteError=error,allowedError=allowed,excess=error-allowed))
        assert counts==[scored[str(c)]['outsideTolerance'] for c in range(shape[0])]
        old_counts=[old_rows[name]['comparison'][str(c)]['outsideTolerance'] for c in range(shape[0])]
        for file in [root/'queued-cuda'/name/'result.json',root/'cases'/name/'input/initial-diagnostic.json']:consumed[str(file)]=sha(file)
        provenance=json.loads((root/'queued-cuda'/name/'result.json').read_text());assert provenance['sourceSHA256']==source_hash
        expected={n:frozen['frozenFiles']['analysis/cuda/'+n]['sha256'] for n in ['run.py','job.py','compile.py']}
        assert provenance['workerFilesSHA256']==expected
        row.update(eligible=scored['passed'],comparison=scored,allPerValueFailures=failures,failureCountsByChannel=counts,
            originalReferenceFailureCountsByChannel=old_counts,validPixels=sum(bool(v) for v in mask),targetShape=shape,
            featureByteIdentity=sha(ref/'inputs.npy')==sha(candidate/'inputs.npy'),maskByteIdentity=sha(ref/'mask.npy')==sha(candidate/'mask.npy'),
            initial=json.loads((root/'cases'/name/'input/initial-diagnostic.json').read_text()))
        rows.append(row)
    assert all(sha(p)==pin for p,pin in consumed.items())
    report=dict(schema='bombcad-fixed-reference-target-audit-1',rows=rows,allThreePilotsPass=len(rows)==3 and all(r['eligible'] for r in rows),
        gate='Exact numeric features/masks and every valid target abs(error)<=0.05+0.002*abs(reference), matching existing compare_dataset.py; additional byte-identity observations do not replace the gate.',
        channelOrder=['peakOverpressure','impulse','firstPhaseImpulse'],consumedFilesSHA256={p.replace(str(root),'$BOMBCAD_DATA/experiments/'+root.name):pin for p,pin in consumed.items()},
        limits='Every planned pilot and every failed valid value retained. Original balloon-reference counts are descriptive history, not same-solution byte parity. Three pilots do not independently validate physics or waive gates on future cases. No tolerance/label/mask/default/training-index change.')
    with output.open('x') as stream:json.dump(report,stream,indent=2);stream.write('\n')
    print(json.dumps(dict(allThreePilotsPass=report['allThreePilotsPass'],cases=[{k:r.get(k) for k in ['id','status','eligible','failureCountsByChannel','originalReferenceFailureCountsByChannel']} for r in rows]),indent=2))


if __name__=='__main__':main(*sys.argv[1:])
