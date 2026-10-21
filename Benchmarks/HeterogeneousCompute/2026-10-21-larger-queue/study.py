"""Eight-case larger replay: isolated complete-queue calibration, three rotated policy rounds."""
import copy,hashlib,importlib.util,json,math,statistics,subprocess,sys,time
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'))
spec=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-larger-queue');root.mkdir(parents=True,exist_ok=False)
exe=Path('.build/release/scenebench').resolve();slot='/Users/louisemmett/.local/bin/gpu-slot'
report=dict(status='running',scope=__doc__,observerClock='Mac time.perf_counter',root=str(root),executableSHA256=q.digest(exe),calibration=[],trials=[],references=[])
def save():q.atomic(root/'study.json',report)
def snapshots(c):return dict(mac=q.mac_snapshot(c),pc=q.pc_snapshot(c))
def quiet(s):return s['pc']['available'] and s['mac'].get('declaredGB')==0 and not s['mac'].get('waiting',True) and s['mac'].get('pressure')=='1'
def run_trial(name,plan):
 queue=root/name;q.atomic(root/(name+'-plan.json'),plan);contract=q.init(plan,queue);before=snapshots(contract)
 if not quiet(before):raise RuntimeError('external workload before '+name+': '+str(before))
 start=time.perf_counter()
 with (root/(name+'.log')).open('w') as log:
  p=subprocess.Popen([sys.executable,str(repo/'Scripts/cuda/field-queue.py'),'run','--queue',str(queue),'--poll','.1','--max-seconds','600'],stdout=log,stderr=subprocess.STDOUT)
  q.atomic(root/'live-controller.json',dict(pid=p.pid,queue=str(queue),name=name))
  code=p.wait(timeout=650)
 elapsed=time.perf_counter()-start
 if code not in (0,1):raise RuntimeError('controller did not complete: '+name+' exit '+str(code))
 states=q.snapshot_states(queue,contract);end=time.perf_counter()+20
 while any(q.tracked_alive(q.read(f)) for f in queue.glob('cases/*/attempts/*/process.json')):
  if time.perf_counter()>end:raise RuntimeError('owned workers remain live '+name)
  time.sleep(.05)
 receipts={j['id']:q.object_receipt(queue,states[j['key']]['object'],contract,j) for j in contract['jobs'] if states[j['key']]['status']=='accepted'}
 row=dict(name=name,queue=str(queue),contract=contract['key'],controllerSeconds=elapsed,exitCode=code,before=before,after=snapshots(contract),states=states,receipts=receipts,allOwnedGroupsTerminal=True)
 q.atomic(root/(name+'-result.json'),row);return row
save()
try:
 dem=root/'slope.asc';n=100
 dem.write_text('ncols 100\nnrows 100\nxllcorner -0.0045\nyllcorner 51.4953\ncellsize 0.0001\nNODATA_value -9999\n'+'\n'.join(' '.join(str(.02*i+.03*(n-1-j)) for i in range(n)) for j in range(n))+'\n')
 jobs=[]
 for terrain in [False,True]:
  for mass in [5,10,20,40]:
   name=('terrain' if terrain else 'uniform')+'-m'+str(mass);ref=root/(name+'-reference')
   args=['--osm',str(repo/'Samples/MapBuildings/synthetic-neighbourhood.geojson'),'--centre','0.00045,51.50028','--radius','128','--dx','2','--height','64','--mass',str(mass),'--until','.16','--above','1','--ground','saturated','--id',name,'--first-phase']
   if terrain:args+=['--dem',str(dem)]
   with (root/(name+'-reference.log')).open('w') as log:subprocess.run([slot,'--mem','1',str(exe),'field-export',*args,'--phase-timings','--out',str(ref)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
   meta=q.read(ref/'meta.json');report['references'].append(dict(id=name,metadata=meta,filesSHA256={f:q.digest(ref/f) for f in q.DATA_FILES}));save()
   jobs.append(dict(id=name,arguments=args,reference=str(ref),physics='recommended-static-terrain' if terrain else 'recommended-uniform',backends=['metal','cuda'],metalGB=max(1,math.ceil((1.25*meta['solverBytes']/1e9+.25)*4)/4),cudaBytes=77*meta['cells']+36*meta['rows']*meta['columns']+8*1048576,timeoutSeconds=300,costs={}))
 initial=root/'initial-cost.json';q.atomic(initial,{'seconds':1.,'scope':'Bootstrap estimate only; not used in policy comparisons'})
 base=dict(format=q.FORMAT,purpose='reference-replay',scenebench=str(exe),cuda={'host':'bombcad-pc','cacheDir':'bombcad-cuda/ptx-cache'},jobs=[])
 blocked=set()
 for repetition in range(3):
  ordered=jobs if repetition%2==0 else list(reversed(jobs))
  for j in ordered:
   for mode in (['metal','cuda'] if repetition%2==0 else ['cuda','metal']):
    if mode=='cuda' and j['id'] in blocked:continue
    plan=copy.deepcopy(base);item=copy.deepcopy(j);item['backends']=[mode];item['costs']={mode:[{'report':str(initial),'keys':['seconds']}]};plan['jobs']=[item]
    row=run_trial(f'cal-{repetition}-{j["id"]}-{mode}',plan);row.update(repetition=repetition,case=j['id'],backend=mode);report['calibration'].append(row);save();print('calibration',row['name'],round(row['controllerSeconds'],3),row['exitCode'],flush=True)
    if row['exitCode']:
     if mode!='cuda':raise RuntimeError('Metal reference replay failed')
     blocked.add(j['id'])
 costs={'scope':'Three isolated one-case controller completion observations per admitted case/backend, including process startup/probes/wait/publication; per-job estimates repeat some shared controller overhead and are an approximation, not additive exact costs','cases':{}}
 for j in jobs:
  name=j['id'];costs['cases'][name]={}
  for mode in ['metal','cuda']:
   rows=[r for r in report['calibration'] if r['case']==name and r['backend']==mode and r['exitCode']==0]
   if mode=='cuda' and name in blocked:continue
   assert len(rows)==3
   values=[r['controllerSeconds'] for r in rows];costs['cases'][name][mode]=dict(medianSeconds=statistics.median(values),samples=values,evidence=[r['queue'] for r in rows])
 q.atomic(root/'calibrated-costs.json',costs)
 eligible=[j['id'] for j in jobs if j['id'] not in blocked];forced=set(eligible[1::2]);report['cudaBlockedCases']=sorted(blocked);report['forcedCudaCases']=sorted(forced);save()
 for repetition in range(3):
  policies=['metal','auto','split'];policies=policies[repetition:]+policies[:repetition]
  for policy in policies:
   plan=copy.deepcopy(base);plan['jobs']=copy.deepcopy(jobs)
   for j in plan['jobs']:
    name=j['id'];modes=['metal'] if policy=='metal' or name in blocked else ['metal','cuda'] if policy=='auto' else ['cuda'] if name in forced else ['metal']
    j['backends']=modes;j['costs']={m:[{'report':str(root/'calibrated-costs.json'),'keys':['cases',name,m,'medianSeconds']}] for m in modes}
   row=run_trial(f'policy-{repetition}-{policy}',plan);assert row['exitCode']==0 and len(row['receipts'])==8
   assert all(s['attempts']==1 and s['status']=='accepted' for s in row['states'].values())
   row.update(repetition=repetition,policy=policy);report['trials'].append(row);save();print('policy',policy,repetition,round(row['controllerSeconds'],3),[(n,r['backend']) for n,r in row['receipts'].items()],flush=True)
 report['summary']={p:dict(medianSeconds=statistics.median(r['controllerSeconds'] for r in report['trials'] if r['policy']==p),samples=[r['controllerSeconds'] for r in report['trials'] if r['policy']==p]) for p in ['metal','auto','split']};report['status']='complete';save()
except BaseException as e:report.update(status='failed',error=repr(e));save();raise
