"""Eight independent replays of one admitted full-flat district: calibrated repeated queue throughput."""
import copy,hashlib,importlib.util,json,math,statistics,subprocess,sys,time
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-full-queue-v2');root.mkdir(parents=True,exist_ok=False)
exe=Path('.build/release/scenebench').resolve();slot='/Users/louisemmett/.local/bin/gpu-slot';original=Path('/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs/made-perimeter-s1-1')
report=dict(status='running',scope=__doc__,root=str(root),executableSHA256=q.digest(exe),controllerSHA256=q.digest(repo/'Scripts/cuda/field-queue.py'),referenceSource=str(original),references=[],calibration=[],trials=[])
def save():q.atomic(root/'study.json',report)
def snapshot(c):return dict(mac=q.mac_snapshot(c),pc=q.pc_snapshot(c))
def quiet(s):return s['pc']['available'] and s['mac'].get('declaredGB')==0 and not s['mac'].get('waiting',True) and s['mac'].get('pressure')=='1'
def observe(command,label,timeout):
 p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,env=q.clean_env(probe))
 identity=q.process_snapshot(p.pid);q.atomic(root/'live-process.json',dict(pid=p.pid,pgid=p.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,label=label,command=command))
 data,_=p.communicate(timeout=timeout);(root/(label+'.log')).write_bytes(data);return p.returncode

def trial(name,plan):
 queue=root/name;q.atomic(root/(name+'-plan.json'),plan);c=q.init(plan,queue);before=snapshot(c)
 if not quiet(before):raise RuntimeError('external workload before '+name+': '+str(before))
 start=time.perf_counter();code=observe([sys.executable,str(repo/'Scripts/cuda/field-queue.py'),'run','--queue',str(queue),'--poll','.25','--max-seconds','1500'],name,1600);elapsed=time.perf_counter()-start
 if code:raise RuntimeError('queue exit '+str(code)+': '+name+'; inspect surviving workers, do not relaunch jobs')
 q.verify_contract(c);states=q.snapshot_states(queue,c);assert all(v['status']=='accepted' and v['attempts']==1 for v in states.values())
 deadline=time.perf_counter()+20
 while any(q.tracked_alive(q.read(p)) for p in queue.glob('cases/*/attempts/*/process.json')):
  if time.perf_counter()>deadline:raise RuntimeError('worker remains live: '+name)
  time.sleep(.05)
 receipts={j['id']:q.object_receipt(queue,states[j['key']]['object'],c,j) for j in c['jobs']}
 requests=[q.read(p) for p in queue.glob('cases/*/attempts/*/request.json')]
 row=dict(name=name,queue=str(queue),contract=c['key'],controllerSeconds=elapsed,before=before,after=snapshot(c),states=states,receipts=receipts,requests=requests,allOwnedGroupsTerminal=True)
 q.atomic(root/(name+'-result.json'),row);return row
save()
try:
 args=q.read(original/'meta.json')['arguments'];physical=[];i=0
 while i<len(args):
  key=args[i]
  if key=='--out':i+=2;continue
  if key in ('--phase-timings',):i+=1;continue
  physical.append(key);i+=1
  if key not in ('--first-phase','--balloon'):
   physical.append(args[i]);i+=1
 probe=dict(cuda={'host':'bombcad-pc'},gpuSlot=slot,slotEnvironment={},revisionObservedAtInit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),worktreeDirtyAtInit=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()))
 before=snapshot(probe);assert quiet(before),before
 jobs=[]
 for index in range(8):
  name=f'full-flat-replay-{index}';arguments=list(physical);arguments[arguments.index('--id')+1]=name;reference=root/(name+'-reference')
  code=observe([slot,'--mem','2',str(exe),'field-export',*arguments,'--phase-timings','--out',str(reference)],name+'-reference',600);assert code==0
  gate=q.compare(original,reference);assert gate['passed'],gate
  meta=q.read(reference/'meta.json');hashes={n:q.digest(reference/n) for n in ['inputs.npy','mask.npy','targets.npy']}
  if report['references']:assert hashes==report['references'][0]['numericalSHA256']
  report['references'].append(dict(id=name,metadata=meta,historicalReferenceGate=gate,numericalSHA256=hashes));save();print('reference',name,meta['cells'],flush=True)
  jobs.append(dict(id=name,arguments=arguments,reference=str(reference),physics='recommended-uniform',backends=['metal','cuda'],metalGB=max(2,math.ceil((1.25*meta['solverBytes']/1e9+.25)*4)/4),cudaBytes=77*meta['cells']+36*meta['rows']*meta['columns']+16*1048576,costs={},timeoutSeconds=600))
 bootstrap=root/'bootstrap-cost.json';q.atomic(bootstrap,dict(seconds=1,scope='bootstrap estimate only, not used in queue comparison'))
 base=dict(format=q.FORMAT,purpose='reference-replay',scenebench=str(exe),cuda={'host':'bombcad-pc','cacheDir':'bombcad-cuda/ptx-cache'},jobs=[])
 for repetition in range(3):
  for backend in (['metal','cuda'] if repetition%2==0 else ['cuda','metal']):
   plan=copy.deepcopy(base);j=copy.deepcopy(jobs[0]);j['backends']=[backend];j['costs']={backend:[{'report':str(bootstrap),'keys':['seconds']}]};plan['jobs']=[j]
   row=trial(f'cal-{repetition}-{backend}',plan);row.update(repetition=repetition,backend=backend);report['calibration'].append(row);save();print('calibration',repetition,backend,round(row['controllerSeconds'],3),flush=True)
 costs=dict(scope='Three isolated complete controller intervals per backend for identical physical full-flat replays; labels differ, numerical reference files are identical; approximate multi-case cost model',backends={})
 for backend in ['metal','cuda']:
  rows=[r for r in report['calibration'] if r['backend']==backend];values=[r['controllerSeconds'] for r in rows];costs['backends'][backend]=dict(medianSeconds=statistics.median(values),samples=values,evidence=[r['queue'] for r in rows])
 q.atomic(root/'calibrated-costs.json',costs)
 for repetition in range(3):
  for policy in (['metal','auto'] if repetition%2==0 else ['auto','metal']):
   plan=copy.deepcopy(base);plan['jobs']=copy.deepcopy(jobs)
   for j in plan['jobs']:
    modes=['metal'] if policy=='metal' else ['metal','cuda'];j['backends']=modes;j['costs']={m:[{'report':str(root/'calibrated-costs.json'),'keys':['backends',m,'medianSeconds']}] for m in modes}
   row=trial(f'policy-{repetition}-{policy}',plan);row.update(repetition=repetition,policy=policy);report['trials'].append(row);save();print('policy',repetition,policy,round(row['controllerSeconds'],3),[(k,v['backend']) for k,v in row['receipts'].items()],flush=True)
 report['summary']={p:dict(medianSeconds=statistics.median(r['controllerSeconds'] for r in report['trials'] if r['policy']==p),samples=[r['controllerSeconds'] for r in report['trials'] if r['policy']==p]) for p in ['metal','auto']};report['status']='complete';save()
except BaseException as e:report.update(status='failed',error=repr(e));save();print('Inspect retained live-process and queue worker identities before any continuation; an observation failure does not prove workers stopped.',flush=True);raise
