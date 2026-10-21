"""Independent post-timing numerical/input/provenance/lifetime audit; no GPU work."""
from pathlib import Path
import json,hashlib
import numpy as np
root=Path(__file__).resolve().parent;labels=['small','full','null-small','null-districts','confirm-small-v2','null-confirm-v2']
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def hashes(p):return {str(q.relative_to(p)):sha(q) for q in p.rglob('*') if q.is_file() and q.suffix in ('.bin','.npy')}
refused=json.loads((root/'confirmation-campaign.json').read_text());assert refused['status']=='failed' and not(root/'confirm-small').exists() and not(root/'confirm-small-state.json').exists()
source=sha(root/'solver.cu');inputs=json.loads((root/'inputs.json').read_text());assert inputs['sourceSHA256']==source
for name,d in inputs['jobs'].items():assert {str(p.relative_to(root/name)):sha(p) for p in (root/name).rglob('*') if p.is_file()}==d['files']
reports=[];canonical={};files=0;bytes_checked=0
for label in labels:
 p=json.loads((root/label/'profile.json').read_text());s=json.loads((root/(label+'-state.json')).read_text());assert s['status']=='complete' and s['returncode']==0 and not s['externalComputeGroupObserved']
 assert all(x['owner'] is None or x['owner']['pid']==s['pid'] for x in s['samples'])
 assert all(x[f].get('returncode')==0 for x in s['samples'] for f in ['gpu','processes'])
 assert p['sourceSHA256']==source and p['profilerSHA256']==sha(root/'profile-worker.py') and p['allOutputsAndTimestepsBitIdentical']
 assert p['baselineCacheDir']==p['candidateCacheDir']==str(Path.home()/'bombcad-cuda/ptx-cache') and p['freshProcessObserver'].startswith('drained stdout/EOF')
 verified=[]
 for row in p['rows']:
  variant='baseline' if label.startswith('null-') else row['worker'];out=root/label/f"{row['job']}-{row['repetition']}-{row['worker']}";r=json.loads((out/'result.json').read_text())
  assert r['workerFilesSHA256']=={'run.py':sha(root/(variant+'.py')),'job.py':sha(root/'job.py'),'compile.py':sha(root/'compile.py')} and p['workerSHA256'][row['worker']]==sha(root/(variant+'.py'))
  assert r['sourceSHA256']==source and r['timingClock']=='clock_gettime(CLOCK_MONOTONIC_RAW)' and r['compileCacheEnabled']
  assert r['wallSeconds']==row['solverSeconds'] and r['steps']==row['steps'];dt=np.load(out/'dt.npy',allow_pickle=False);assert len(dt)==r['steps'] and sum(map(float,dt))==r['elapsedSimulationTime']==row['elapsedSimulationTime']
  actual=hashes(out);assert actual==row['hashes']
  if row['job'] in canonical:assert actual==canonical[row['job']]
  else:canonical[row['job']]=actual
  files+=len(actual);bytes_checked+=sum((out/n).stat().st_size for n in actual);verified.append(dict(job=row['job'],repetition=row['repetition'],worker=row['worker'],variant=variant,resultSHA256=sha(out/'result.json'),numericalFiles=len(actual)))
 reports.append(dict(profile=label,profileSHA256=sha(root/label/'profile.json'),monitorSHA256=sha(root/(label+'-state.json')),samples=len(s['samples']),unresolvedGroups=sum(x.get('exitedBeforeGroupRead',False) for sample in s['samples'] for x in sample.get('observed',[])),allResolvedGroupsOwned=all(x.get('ownedGroup') is not False for sample in s['samples'] for x in sample.get('observed',[])),runs=verified))
historical=0
for label in ['small64','small256','full64','full256','null-small','null-districts']:
 p=json.loads((Path.home()/'bombcad-blocks-01a15d45'/label/'profile.json').read_text())
 for row in p['rows']:assert row['hashes']==canonical[row['job']];historical+=1
d=json.loads((root/'diagnostic/diagnostic.json').read_text());assert d['status']=='complete' and d['allFullOutputsAndTimestepsBitIdentical'] and d['actualDevicePayloadsByteExactAfterPrepare'] and d['exactByteHitMissAndBoundedLifetimeChecked']
for row in d['trace']:
 p=root/'diagnostic'/('trace-'+row['worker']);assert hashes(p)==row['hashes']==canonical['blast64'] and sha(p/'result.json')==row['resultSHA256']
for case in d['pairs']:
 for row in case['rows']:
  p=root/'diagnostic'/(case['case']+'-'+row['worker']);r=json.loads((p/'result.json').read_text());assert hashes(p)==row['hashes']==case['rows'][0]['hashes'] and sha(p/'result.json')==row['resultSHA256']
  assert r['sourceSHA256']==source and r['workerFilesSHA256']=={'run.py':sha(root/(row['worker']+'.py')),'job.py':sha(root/'job.py'),'compile.py':sha(root/'compile.py')}
  c=row['cache'];assert c['allDevicePayloadsExactAndReadOnly'] and c['maxLivePrepareObjects']<=3 and c['livePrepareObjectsAfterReturn']==0
  assert c['prepareUploads']==(c['byteMisses'] if row['worker']=='candidate' else c['prepareCalls'])
assert len(d['failures'])==4 and all(c['noOutputWritten'] and not(root/'diagnostic'/(c['case']+'-'+c['worker'])).exists() for c in d['failures'])
owned={json.loads((root/(label+'-state.json')).read_text())['pgid'] for label in labels};live=[]
for stat in Path('/proc').glob('[0-9]*/stat'):
 try:
  fields=stat.read_text().rsplit(')',1)[1].split()
  if int(fields[2]) in owned and fields[0]!='Z':live.append(str(stat.parent))
 except (OSError,ValueError,IndexError):continue
assert not live,live
result=dict(status='complete',allSourcesInputsProvenanceAndNumericalFilesVerified=True,allTimedGroupsTerminal=True,preDispatchGuardRefusalRetained=True,timedRuns=sum(len(r['runs']) for r in reports),numericalFileInstances=files,numericalBytesVerified=bytes_checked,historicalBlockStudyRowsMatch=historical,sourceSHA256=source,workerSHA256={n:sha(root/(n+'.py')) for n in ['baseline','candidate']},reports=reports,diagnosticSHA256=sha(root/'diagnostic/diagnostic.json'),diagnosticSuccesses=len(d['trace'])+sum(len(c['rows']) for c in d['pairs']),expectedFailures=len(d['failures']),limits='Periodic resource samples are not laboratory exclusivity. Numerical CUDA parity is not dataset admission. Device readback/lifetime instrumentation is perturbing and outside timing.')
(root/'verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k!='reports'},indent=2))
