import copy,importlib.util,json,subprocess,sys,time
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
version=sys.argv[1];root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-cost-probe')/version;root.mkdir(parents=True,exist_ok=False)
old=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-larger-queue');base=q.read(old/'policy-0-auto-plan.json')
report=dict(status='running',version=version,controllerSHA256=q.digest(repo/'Scripts/cuda/field-queue.py'),trials=[])
def save():q.atomic(root/'study.json',report)
def snapshot(c):return dict(mac=q.mac_snapshot(c),pc=q.pc_snapshot(c))
save()
try:
 policies=[(r,p) for r in range(3) for p in (['auto','metal'] if r%2==0 else ['metal','auto'])]+[(0,'cuda-control')]
 for repetition,policy in policies:
  plan=copy.deepcopy(base)
  if policy=='cuda-control':plan['jobs']=[plan['jobs'][1]]
  for j in plan['jobs']:
   j['backends']=['metal','cuda'] if policy=='auto' else ['cuda'] if policy=='cuda-control' else ['metal'];j['costs']={m:j['costs'][m] for m in j['backends']}
  name=f'{repetition}-{policy}';queue=root/name;q.atomic(root/(name+'-plan.json'),plan);c=q.init(plan,queue);before=snapshot(c)
  if not before['pc']['available'] or before['mac']['declaredGB'] or before['mac']['waiting'] or before['mac']['pressure']!='1':raise RuntimeError('external workload detected')
  start=time.perf_counter()
  with (root/(name+'.log')).open('w') as log:
   p=subprocess.Popen([sys.executable,str(repo/'Scripts/cuda/field-queue.py'),'run','--queue',str(queue),'--poll','.1','--max-seconds','180'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   data,_=p.communicate(timeout=200);log.write(data.decode(errors='replace'))
  elapsed=time.perf_counter()-start;assert p.returncode==0
  q.verify_contract(c);states=q.snapshot_states(queue,c);assert all(v['status']=='accepted' and v['attempts']==1 for v in states.values())
  deadline=time.perf_counter()+10
  while any(q.tracked_alive(q.read(f)) for f in queue.glob('cases/*/attempts/*/process.json')):
   if time.perf_counter()>deadline:raise RuntimeError('owned worker remains live')
   time.sleep(.05)
  receipts={j['id']:q.object_receipt(queue,states[j['key']]['object'],c,j) for j in c['jobs']}
  requests=[q.read(f) for f in queue.glob('cases/*/attempts/*/request.json')]
  report['trials'].append(dict(repetition=repetition,policy=policy,queue=str(queue),contract=c['key'],controllerSeconds=elapsed,before=before,after=snapshot(c),receipts=receipts,requests=requests,states=states,allOwnedGroupsTerminal=True));save();print(version,policy,repetition,round(elapsed,3),flush=True)
 report['status']='complete';save()
except BaseException as e:report.update(status='failed',error=repr(e));save();raise
