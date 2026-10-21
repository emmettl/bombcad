"""Audit saved judgments without launching or repeating field-walls."""
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);r=json.loads((root/'study.json').read_text());d=json.loads((root/'judged.json').read_text())
for p,h in r['pinsSHA256'].items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
out=dict(status='complete',scope='Saved CPU product-model outcomes only; no new solver or judgement launch.',buildings=len(d['buildings']),variants={},identicalControl=True)
for variant in r['variants']:
 out['variants'][variant]={}
 for metric in ['wallsModerate','wallsHeavy','roofModerate']:
  pairs=[]
  for i,pair in enumerate(d['grid']):
   deltas=[];locations=[]
   for b in d['buildings']:
    if b.get('roof' if metric=='roofModerate' else 'wall') is None:continue
    a=b[metric]['default:default'][i];c=b[metric][variant][i]
    assert b[metric]['repeat:repeat'][i]==a
    deltas.append(abs(c-a))
    if a!=c:locations.append(dict(object=b['object'],distanceM=b['distanceM'],construction=b['walls'],reference=a,candidate=c))
   pairs.append(dict(pair=pair,buildings=len(deltas),changed=len(locations),maxAbsolute=max(deltas,default=0),meanAbsolute=sum(deltas)/max(1,len(deltas)),locations=locations))
  out['variants'][variant][metric]=pairs
(root/'analysis.json').write_text(json.dumps(out,indent=2)+'\n')
print('Audited saved judgement',out['buildings'],'buildings',len(out['variants']),'variants')
for v,metrics in out['variants'].items():print(v,{m:[p['changed'] for p in ps] for m,ps in metrics.items()})
