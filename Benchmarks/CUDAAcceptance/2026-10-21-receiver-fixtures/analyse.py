"""Audit all declared pairs and saved fixture responses; no study launch or policy selection."""
import hashlib,json
from pathlib import Path
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-receiver-fixtures');study=json.loads((root/'study.json').read_text());pins=json.loads((root/'runtime-pins.json').read_text())
for p,h in {**study['sourceSHA256'],**pins}.items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
result=dict(status='partial',scope=study['scope'],hosts={},duplicateControlsIdentical=True)
for host in ['here','bombcad-pc']:
 folder=root/'results'/('receiver-fixtures-20261021-'+host)
 if not (folder/'sweep.json').exists():continue
 report=dict(rows=0,comparisons=[],levelChanges=[],maxRotationDeltaDeg=0.,maxRotationRelative=0.,maxRawImpulseRelativeError=0.,assessmentFailures=[])
 for step in study['bins']:
  rows=json.loads((folder/f'bin-{step}'/'results.json').read_text());assert len(rows)==640;report['rows']+=len(rows)
  lookup={(r['load'],r['fixture'],r['policy']):r for r in rows}
  for row in rows:
   if row['policy']=='raw':
    expected=study['sourcePairs'][row['load']][1];error=abs(row['integratedImpulsePaS']/expected-1);report['maxRawImpulseRelativeError']=max(report['maxRawImpulseRelativeError'],error);assert error<1e-9
   if row.get('damage') is None:report['assessmentFailures'].append(dict(binS=step,**row))
  for point in study['points']:
   for fixture in study['fixtures']:
    for policy in ['raw','product-3pct']:
     base=lookup[(point['loads']['default'],fixture['id'],policy)];repeat=lookup[(point['loads']['repeat'],fixture['id'],policy)]
     assert base.get('damage')==repeat.get('damage') and base['integratedImpulsePaS']==repeat['integratedImpulsePaS']
     for name,ident in point['loads'].items():
      if name in ['default','repeat']:continue
      other=lookup[(ident,fixture['id'],policy)];a,b=base.get('damage'),other.get('damage')
      if a is None or b is None:continue
      delta=max(abs(x-y) for x,y in zip(a['rotationDeg'],b['rotationDeg']));relative=max(abs(x-y)/max(abs(x),1e-30) for x,y in zip(a['rotationDeg'],b['rotationDeg']))
      report['maxRotationDeltaDeg']=max(report['maxRotationDeltaDeg'],delta);report['maxRotationRelative']=max(report['maxRotationRelative'],relative)
      item=dict(point=point['id'],fixture=fixture['id'],variant=name,policy=policy,binS=step,referenceLevels=a['levels'],candidateLevels=b['levels'],rotationDeltaDeg=delta,rotationRelative=relative,referenceRotationDeg=a['rotationDeg'],candidateRotationDeg=b['rotationDeg'],referenceFailedAtS=a.get('failedAtS'),candidateFailedAtS=b.get('failedAtS'))
      report['comparisons'].append(item)
      if a['levels']!=b['levels']:report['levelChanges'].append(item)
 result['hosts'][host]=report
 if host=='here':
  # A bin-width sensitivity check, not a convergence proof or an error bound.
  maps={step:{(r['load'],r['fixture'],r['policy']):r for r in json.loads((folder/f'bin-{step}'/'results.json').read_text())} for step in study['bins']}
  fine=maps[min(study['bins'])];variation=[]
  for step,mapping in maps.items():
   deltas=[];levelchanges=0
   for key,row in mapping.items():
    a,b=row.get('damage'),fine[key].get('damage')
    if a is None or b is None:continue
    deltas.append(max(abs(x-y) for x,y in zip(a['rotationDeg'],b['rotationDeg'])));levelchanges+=a['levels']!=b['levels']
   variation.append(dict(binS=step,levelsDifferentFromFinest=levelchanges,maxRotationDeltaFromFinestDeg=max(deltas,default=0)))
  result['binWidthSensitivity']=variation
if len(result['hosts'])==2:result['status']='complete'
(root/'analysis.json').write_text(json.dumps(result,indent=2)+'\n')
for host,r in result['hosts'].items():
 print(host,'rows',r['rows'],'level changes',len(r['levelChanges']),'max rotation delta',r['maxRotationDeltaDeg'],'max relative',r['maxRotationRelative'],'nil assessments',len(r['assessmentFailures']))
 for row in r['levelChanges'][:15]:print(row)
print(result.get('binWidthSensitivity'))
