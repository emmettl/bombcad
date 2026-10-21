import hashlib,json,subprocess,time,statistics
from pathlib import Path
root=Path('/private/tmp/bombcad-metal-setup');binary=Path('.build/release/scenebench').resolve()
plan=json.loads(Path('/private/tmp/bombcad-queue-cost-study/0-metal-plan.json').read_text())
record=dict(format='bombcad-metal-setup-study-1',binary=str(binary),binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),runs=[])
def save():(root/'study.json').write_text(json.dumps(record,indent=2)+'\n')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for repetition in range(3):
 for job in plan['jobs']:
  for mode in ['metal','cuda-prepare']:
   controls={}
   for timed in ([False,True] if repetition%2==0 else [True,False]):
    label=f'{job["id"]}-{mode}-{repetition}-'+('timed' if timed else 'plain');out=root/label
    args=[str(binary),'field-export',*job['arguments'],'--out',str(out)]
    if mode=='cuda-prepare':args+=['--cuda-job','--cuda-source',str(root/'solver.cu')]
    if timed:args+=['--phase-timings']
    snapshot=subprocess.check_output(['/Users/louisemmett/.local/bin/gpu-slot','--status'],text=True)
    start=time.perf_counter()
    with (root/(label+'.log')).open('w') as log:subprocess.run(['/Users/louisemmett/.local/bin/gpu-slot','--mem','1',*args],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
    item=dict(case=job['id'],mode=mode,repetition=repetition,timed=timed,outerSeconds=time.perf_counter()-start,arguments=args,slotBefore=snapshot,filesSHA256={p.name:sha(p) for p in out.iterdir() if p.suffix=='.npy'})
    assert item['filesSHA256']
    if timed:
     r=json.loads((out/'phase-timings.json').read_text());phases=r['solverSetupPhasesSeconds'];assert len(phases)==6 and all(v>=0 for v in phases.values());assert sum(phases.values())<=r['seconds']['solverSetupIncludingCompileSeconds']+1e-5
     item['phases']=r
    else:assert not (out/'phase-timings.json').exists()
    controls[timed]=item['filesSHA256'];record['runs'].append(item);save()
   assert controls[True]==controls[False],label
   print('identical',job['id'],mode,repetition,flush=True)
record['status']='complete';save()
