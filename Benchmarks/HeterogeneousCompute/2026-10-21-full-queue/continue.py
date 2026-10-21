"""Continue after a real external-load interruption; retain and replace the entire affected pair."""
import copy,importlib.util,json,os,re,shutil,signal,statistics,subprocess,sys,time
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-full-queue-v2');report=q.read(root/'study.json');assert report['status']=='failed' and len(report['trials'])==2
shutil.copy2(root/'study.json',root/'interrupted-study.json')
slot='/Users/louisemmett/.local/bin/gpu-slot';base=q.read(root/'policy-0-auto-plan.json');probe=q.read(root/'policy-1-auto'/'contract.json');q.verify_contract(probe)
assert not list((root/'policy-1-auto').glob('cases/*/attempts/*'))
def snapshot(c):return dict(mac=q.mac_snapshot(c),pc=q.pc_snapshot(c))
def quiet(v):return v['pc']['available'] and v['mac'].get('declaredGB')==0 and not v['mac'].get('waiting',True) and v['mac'].get('pressure')=='1'
initial=snapshot(probe);q.atomic(root/'continuation-preflight.json',initial);assert quiet(initial),initial
report['interruptions']=[dict(error=report.pop('error'),resolution='All 22 owned workers terminal. Next initialized queue has no attempts. External slot holder finished; two coordinating sessions report no planned GPU work. Entire prior pair excluded/replaced regardless of timing.')]
for row in report['trials']:row.update(included=False,exclusionReason='External GPU slot present in automatic post-trial snapshot; conservatively exclude the whole pair')
report.update(status='running',monitorProtocol='Sample GPU slot ownership during each ten-second communicate observation interval; identify owned worker process groups. External live owner interrupts controller; active workers finish. Both included policies use this observer. Sampling cannot rule out brief unsampled work.')
def save():q.atomic(root/'study.json',report)
def monitor(queue):
 groups={q.read(p)['pgid'] for p in queue.glob('cases/*/attempts/*/process.json')}
 text=subprocess.check_output([slot,'--status'],text=True,timeout=10);owners=[]
 for pid in re.findall(r'slot \d+: pid (\d+)',text):
  try:pgid=os.getpgid(int(pid))
  except ProcessLookupError:continue
  owners.append(dict(pid=int(pid),pgid=pgid,owned=pgid in groups))
 return dict(observedAt=time.time(),status=text,owners=owners,external=any(not x['owned'] for x in owners))
def terminal(queue):return not any(q.tracked_alive(q.read(p)) for p in queue.glob('cases/*/attempts/*/process.json'))
def trial(name,plan,rep,policy):
 queue=root/name
 if queue.exists():
  assert name=='policy-1-auto' and q.read(root/(name+'-plan.json'))==plan
  assert not list(queue.glob('cases/*/attempts/*')) and not list((queue/'objects').iterdir())
  c=q.read(queue/'contract.json');q.verify_contract(c)
 else:q.atomic(root/(name+'-plan.json'),plan);c=q.init(plan,queue)
 before=snapshot(c)
 if not quiet(before):raise RuntimeError('external workload before '+name+': '+str(before))
 start=time.perf_counter();p=subprocess.Popen([sys.executable,str(repo/'Scripts/cuda/field-queue.py'),'run','--queue',str(queue),'--poll','.25','--max-seconds','1500'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
 identity=q.process_snapshot(p.pid);q.atomic(root/'live-process.json',dict(pid=p.pid,pgid=p.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,label=name))
 deadline=time.perf_counter()+1600;samples=[];interrupted=False
 while True:
  try:data,_=p.communicate(timeout=min(10,max(.1,deadline-time.perf_counter())));break
  except subprocess.TimeoutExpired:
   if time.perf_counter()>deadline:raise RuntimeError('Controller still observed live beyond budget; inspect same process, do not restart')
   item=monitor(queue);samples.append(item)
   if item['external'] and not interrupted:
    interrupted=True;p.send_signal(signal.SIGINT)
 elapsed=time.perf_counter()-start;(root/(name+'.log')).write_bytes(data)
 end=time.perf_counter()+650
 while not terminal(queue):
  if time.perf_counter()>end:raise RuntimeError('owned workers still live; observe their identities')
  time.sleep(.2)
 after=snapshot(c);q.atomic(root/(name+'-monitor.json'),samples)
 if p.returncode or interrupted or not quiet(after):raise RuntimeError('Interrupted/contended trial retained: '+name+' exit '+str(p.returncode)+' after '+str(after))
 q.verify_contract(c);states=q.snapshot_states(queue,c);assert all(x['status']=='accepted' and x['attempts']==1 for x in states.values())
 receipts={j['id']:q.object_receipt(queue,states[j['key']]['object'],c,j) for j in c['jobs']};requests=[q.read(p) for p in queue.glob('cases/*/attempts/*/request.json')]
 row=dict(name=name,queue=str(queue),contract=c['key'],controllerSeconds=elapsed,before=before,after=after,states=states,receipts=receipts,requests=requests,repetition=rep,policy=policy,included=True,slotOwnershipSamples=samples,allOwnedGroupsTerminal=True)
 q.atomic(root/(name+'-result.json'),row);report['trials'].append(row);save();print('policy',rep,policy,round(elapsed,3),[(n,v['backend']) for n,v in receipts.items()],flush=True)
save()
try:
 for rep,policy,replacement in [(1,'auto',False),(1,'metal',False),(2,'metal',False),(2,'auto',False),(0,'metal',True),(0,'auto',True)]:
  plan=copy.deepcopy(base)
  for j in plan['jobs']:
   j['backends']=['metal'] if policy=='metal' else ['metal','cuda'];j['costs']={m:j['costs'][m] for m in j['backends']}
  trial(('replacement-' if replacement else '')+f'policy-{rep}-{policy}',plan,rep,policy)
 included=[r for r in report['trials'] if r['included']];assert len(included)==6
 report['summary']={p:dict(medianSeconds=statistics.median(r['controllerSeconds'] for r in included if r['policy']==p),samples=[r['controllerSeconds'] for r in included if r['policy']==p]) for p in ['metal','auto']};report['status']='complete';save()
except BaseException as e:report.update(status='failed',error=repr(e));save();raise
