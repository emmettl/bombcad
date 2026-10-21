"""Retain exact source snapshots, traces and metadata; large datasets remain at hashed scratch paths."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,sys
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
s=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(s);s.loader.exec_module(phase)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2');scratch=Path('/private/tmp/bombcad-pressure');dest=repo/'Benchmarks/CUDAAcceptance/2026-10-21-production-pressure'
assert q.read(root/'audit.json')['status']=='complete' and q.read(root/'cuda-audit.json')['status']=='complete';r=q.read(root/'study.json')
for n,h in r['sourceFilesSHA256'].items():assert q.digest(n)==h,n
u=q.read(root/'unfused.json');assert u['status']=='complete' and len(u['commands'])==2;extra_arrays=0;extra_bytes=0
for command in u['commands']:assert command['returncode']==0 and not q.group_alive(command['pgid'])
for variant in u['variants']:
 folder=root/'unfused'/variant['mode'];assert q.read(folder/'diagnostic-state-hashes.json')==variant['state']
 assert {str(p.relative_to(folder)):q.digest(p) for p in folder.rglob('*.npy') if not p.name.endswith('trace.npy')}==variant['hashes']
 extra_arrays+=len(variant['hashes']);extra_bytes+=sum((folder/n).stat().st_size for n in variant['hashes'])
assert u['variants'][0]['hashes']==u['variants'][1]['hashes'] and u['variants'][0]['state']==u['variants'][1]['state']
m,d=phase.load(root/'unfused/pressure');summary=phase.summarize(m,d);assert summary==q.read(root/'unfused/pressure/replay.json') and all(c['float32Replay']['recorderValuesDifferent']==0 for c in summary['columns'])
q.atomic(root/'unfused-audit.json',dict(status='complete',sourceAndFullArraysStateVerified=True,allOwnedGroupsTerminal=True,wholeTraceSeparateAccumulationExact=True,arrayInstancesVerified=extra_arrays,arrayBytesVerified=extra_bytes))
dest.mkdir(exist_ok=False)
raw={str(p.relative_to(root)):dict(sha256=q.digest(p),bytes=p.stat().st_size) for p in sorted(root.rglob('*')) if p.is_file()}
q.atomic(dest/'retained-files.json',raw)
metadata={}
for p in sorted(root.rglob('*')):
 if p.is_file() and (p.suffix in ['.json','.log','.patch'] or p.name in ['trace.npy','pressure-trace.npy','production-trace.npy']):
  n=p.relative_to(root);target=dest/'evidence'/n;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target);assert q.digest(target)==raw[str(n)]['sha256'];metadata[str(n)]=q.digest(target)
q.atomic(dest/'metadata-files.json',metadata)
for name in ['study.py','study.log','study-v1.py.txt','study-v1-init.log','audit.py','audit.log','cuda-flat.py','cuda-flat-controller.log','audit-cuda.py','audit-cuda.log','phase-decision.py','phase-decision.log','unfused.py','unfused-controller.log','package.py','plan.md','phase-cpu.log','cpu-tests-host.log','linux-phase-tests.log','seed-json-smoke.py','seed-json-smoke.json','gpu-tests-v1-nonfused-replay.log','gpu-tests-v2.log','gpu-tests-v3.log','build.log','build-host.log','release-build.log','release-build-v2.log']:
 shutil.copy2(scratch/name,dest/name)
source_names=['Scripts/cuda/diagnose-phase.py','Scripts/cuda/test_phase_pressure.py','Scripts/cuda/test_backend.py','Sources/BlastCore/FirstPhaseColumns.swift','Sources/BlastCore/StructureTypes+GPU.swift','Sources/SceneBench/FieldExport.swift','Tests/BlastCoreTests/FirstPhaseColumnsTests.swift'];sources={}
for name in source_names:
 p=repo/name;target=dest/'source'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target);sources[name]=q.digest(target);assert sources[name]==r['sourceFilesSHA256'][str(p)] if str(p) in r['sourceFilesSHA256'] else name.startswith('Tests/')
q.atomic(dest/'source-snapshot.json',sources)
q.atomic(dest/'package-audit.json',dict(status='complete',scope=__doc__,rawFileInstancesHashed=len(raw),rawBytesHashed=sum(v['bytes'] for v in raw.values()),metadataAndTraceFilesCopiedAndRehashed=len(metadata),exactCandidateSourceSnapshots=len(sources),extraUnfusedArrayInstancesVerified=extra_arrays,extraUnfusedArrayBytesVerified=extra_bytes))
print('Retained',len(raw),'raw receipts;',len(metadata),'metadata/trace copies;',len(sources),'source snapshots')
