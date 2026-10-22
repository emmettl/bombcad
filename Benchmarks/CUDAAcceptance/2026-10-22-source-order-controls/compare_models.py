"""All-case direct model-array comparison after equal aggregate counts; no GPU."""
import hashlib
import json
from pathlib import Path
import sys
import numpy as np


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def main(root,base):
    root=Path(root);base=Path(base);run=json.loads((root/'run.json').read_text())
    assert run['status']=='complete-all-outcomes' and len(run['rows'])==432
    archive=base.parent/'2026-10-22-host-source-publication/scientific-archive.json'
    assert sha(archive)==run['predecessorArchiveSHA256']
    inventory=json.loads(archive.read_text())['allRawFiles'];rows=[];consumed={}
    for row in run['rows']:
        result=dict(label=row['label'],status='unavailable')
        try:
            assert row['status']=='audited'
            old=base/'audit/components'/(row['label']+'.npz');new=root/'flux'/(row['label']+'.npz')
            key=str(old.relative_to(base));assert sha(old)==inventory[key]['sha256']
            assert sha(new)==row['derivedFileSHA256'];consumed[key]=inventory[key]
            models={}
            with np.load(old,allow_pickle=False) as a,np.load(new,allow_pickle=False) as b:
                for oldkey,newkey,word in [('separate32_flux','written32',np.uint32),('stored64_flux','written64',np.uint64)]:
                    x=a[oldkey];y=b[newkey];assert x.dtype==y.dtype and x.shape==y.shape
                    different=x.view(word)!=y.view(word)
                    models[newkey]=dict(wordDifferencesByComponent=np.count_nonzero(different,axis=(0,1)).tolist(),
                        maximumAbsoluteDifferenceByComponent=np.max(np.abs(x.astype(np.float64)-y.astype(np.float64)),axis=(0,1)).tolist(),
                        wholeTraceBitIdentical=not different.any())
            result.update(status='compared',models=models)
        except Exception as error:result.update(status='failed',error=repr(error))
        rows.append(result)
    for name,pin in consumed.items():assert sha(base/name)==pin['sha256']
    assert sha(archive)==run['predecessorArchiveSHA256']
    totals={}
    for name in ['written32','written64']:
        values=[r['models'][name] for r in rows if r['status']=='compared']
        totals[name]=dict(comparedCases=len(values),wholeTraceBitIdenticalCases=sum(v['wholeTraceBitIdentical'] for v in values),
            wordDifferencesByComponent=[sum(v['wordDifferencesByComponent'][i] for v in values) for i in range(3)],
            maximumAbsoluteDifferenceByComponent=[max((v['maximumAbsoluteDifferenceByComponent'][i] for v in values),default=None) for i in range(3)])
    report=dict(status='complete-all-outcomes',rows=rows,consumedPriorFiles=consumed,models=totals,
        allCasesCompared=all(r['status']=='compared' for r in rows),sourceSHA256=sha(__file__),
        scope=__doc__,limits='Two CPU counterfactual model arrays compared; equality does not establish GPU intermediate/instruction equality, physical fidelity or equivalence outside these observed inputs.')
    with (root/'model-equivalence.json').open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['rows','consumedPriorFiles']},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
