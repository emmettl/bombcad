"""Independent post-run file, state, history and arithmetic audit; no GPU execution."""
from pathlib import Path
import gzip,hashlib,importlib.util,json,math,sys
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'))
s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
s=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(s);s.loader.exec_module(phase)
from generate import generate
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2');r=q.read(root/'study.json');assert r['status']=='complete' and len(r['cases'])==4 and len(r['commands'])==15
assert [c['name'] for c in r['cases']]==['small-layers','terrain','beirut','flat-half']
assert sum(c['historicalArraysBitIdentical'] is not None for c in r['cases'])==3
for n,h in r['sourceFilesSHA256'].items():assert q.digest(n)==h,n
for command in r['commands']:
 assert not q.group_alive(command['pgid']),command
 assert (command['returncode']!=0)==command['label'].startswith('refused-')
assert len(r['failures'])==3 and all(x['noOutputWritten'] and not(root/('refused-'+x['case'])).exists() for x in r['failures'])
source_hash=hashlib.sha256(generate().encode()).hexdigest();prior=q.read(repo/'Benchmarks/HeterogeneousCompute/2026-10-21-distinct-queue/evidence/stage.json')['sourceSHA256'];assert source_hash==prior
rows=[];files=0;bytes_checked=0
for case in r['cases']:
 base=root/case['name'];variants=case['variants'];assert len(variants)==3
 names=[n for n in variants[0]['filesSHA256'] if not n.endswith('trace.npy')]
 for variant in variants:
  folder=base/variant['mode'];assert q.read(folder/'meta.json')==variant['meta'] and variant['meta']['stable']
  assert q.read(folder/'diagnostic-state-hashes.json')==variant['stateHashes']
  assert {str(p.relative_to(folder)):q.digest(p) for p in folder.rglob('*.npy')}==variant['filesSHA256']
  for name in names:
   p=folder/name;shape,values=q.npy(p);assert all(math.isfinite(v) for v in values)
   if name.endswith('mask.npy'):assert all(v in (0,1) for v in values)
   files+=1;bytes_checked+=p.stat().st_size
  for group in ['initial','final']:
   hashes=variant['stateHashes'][group];assert {'state','peak','impulse','mask','firstPhaseColumns','firstPhaseRecords','firstPhaseOpen'}<=set(hashes)
   assert all(len(h)==64 and all(c in '0123456789abcdef' for c in h) for h in hashes.values())
 arrays_match=all(len({v['filesSHA256'][n] for v in variants})==1 for n in names)
 state_match=variants[0]['stateHashes']==variants[1]['stateHashes']==variants[2]['stateHashes']
 historical=all(q.digest(Path(case['reference'])/n)==q.digest(base/'plain'/n) for n in q.DATA_FILES if n!='meta.json') if case['reference'] else None
 m,d=phase.load(base/'pressure');summary=phase.summarize(m,d);assert summary==q.read(base/'pressure/replay.json')
 policies=set(['separate','fused']);closures=[]
 for column in summary['columns']:
  policies.intersection_update(column['exactAccumulationPolicies'])
  qcol=m['columns'].index(column['column']);events=[]
  for step in column['float32FusedReplay']['closingSamples']:
   start=(step*len(m['columns'])+qcol)*8
   events.append(dict(sample=step,time=m['times'][step],actualConsumedPressurePa=d[start],recorder=list(d[start+1:start+6])))
  closures.append(dict(column=column['column'],events=events,finalFirstPhaseImpulse=column['float32FusedReplay']['finalFirstPhaseImpulse']))
 assert sorted(policies)==case['wholeTraceExactAccumulationPolicies'] and policies
 lm=q.read(base/'legacy/production-trace.json');shape,lv=q.npy(base/'legacy/production-trace.npy');count=len(m['columns']);lookup={n:i for i,n in enumerate(m['columns'])}
 history=lm['steps']==m['steps'][1:] and lm['times']==m['times'][1:] and all(list(lv[(step*len(lm['columns'])+index)*8:(step*len(lm['columns'])+index)*8+5])==list(d[((step+1)*count+lookup[column])*8+1:((step+1)*count+lookup[column])*8+6]) for step in range(shape[0]) for index,column in enumerate(lm['columns']))
 assert [arrays_match,state_match,history,historical]==[case['arrayParity'],case['initialAndFinalStateParity'],case['recorderHistoryParity'],case['historicalArraysBitIdentical']]
 archived_name={'terrain':'made-perimeter-s3-1-tiled','beirut':'beirut-p0-1-tiled'}.get(case['name'])
 archived_history=None
 if archived_name:
  archived=repo/'Benchmarks/CUDAAcceptance/2026-10-21-production-traces'/archived_name
  old_meta=q.read(archived/'production-trace.json')
  archived_history=(hashlib.sha256(gzip.decompress((archived/'production-trace.npy.gz').read_bytes())).hexdigest()==q.digest(base/'legacy/production-trace.npy') and old_meta['steps']==lm['steps'] and old_meta['times']==lm['times'])
 rows.append(dict(case=case['name'],archivedRecorderTraceBytesAndClocksMatch=archived_history,arraysBitIdentical=arrays_match,initialFinalCompleteCoarseStateHashesMatch=state_match,recorderHistoryBitIdentical=history,historicalArraysBitIdentical=historical,activeSteps=len(m['steps'])-1,pressureColumns=m['columns'],wholeTraceExactAccumulationPolicies=sorted(policies),closures=closures))
report=dict(status='complete',scope=__doc__,allOwnedCommandGroupsTerminal=True,successfulCommands=12,expectedRefusals=3,datasetArrayInstancesVerified=files,datasetArrayBytesVerified=bytes_checked,defaultGeneratedCUDASourceUnchanged=source_hash,allCasesPassParity=all(c['arraysBitIdentical'] and c['initialFinalCompleteCoarseStateHashesMatch'] and c['recorderHistoryBitIdentical'] for c in rows),allThreeHistoricalReferencesMatch=all(c['historicalArraysBitIdentical'] for c in rows if c['historicalArraysBitIdentical'] is not None),bothArchivedRecorderHistoriesMatch=all(c['archivedRecorderTraceBytesAndClocksMatch'] for c in rows if c['archivedRecorderTraceBytesAndClocksMatch'] is not None),cases=rows,limits='Hashes cover complete coarse fluid/species, accumulated fields, mask and first-phase buffers; not structural/refinement state. Compatible arithmetic is not emitted-instruction attestation. Instrumented consumed pressure with matched outputs is not a proof that every unobserved intermediate of an uninstrumented binary is identical. No physical validation or admission-policy change.')
q.atomic(root/'audit.json',report);print(json.dumps(report,indent=2))
