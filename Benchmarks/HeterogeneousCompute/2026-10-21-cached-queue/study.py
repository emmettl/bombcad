import sys,importlib.util,json,subprocess,time,uuid,hashlib
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path('Scripts/cuda').resolve()))
s=importlib.util.spec_from_file_location('queue','Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
out=Path('/private/tmp/bombcad-cached-queue');record={'status':'running','trials':[]}
base=json.loads(Path('/private/tmp/bombcad-queue-cost-study/0-metal-plan.json').read_text());base['scenebench']=str(Path('.build/release/scenebench').resolve());base['jobs']=[base['jobs'][1]]
job=base['jobs'][0];job['backends']=['cuda'];job['costs']={'cuda':[{'report':str(Path('Benchmarks/HeterogeneousCompute/2026-10-21-queue-costs/observed-costs.json').resolve()),'keys':['cases','queue-m10','cuda','workerBodyMedianSeconds']}]}
for trial in range(3):
 root=out/f'queue-{trial}'
 if trial:job['cachedCudaCosts']=[{'report':str(out/'cached-cost.json'),'keys':['workerBodySeconds']}]
 q.atomic(out/f'plan-{trial}.json',base);c=q.init(base,root);j=c['jobs'][0];key=j['key'];a=uuid.uuid4().hex;attempt=root/'cases'/key/'attempts'/a;attempt.mkdir()
 request={'backend':'cuda','generation':0,'createdAt':time.time(),'decision':{'case':key,'backend':'cuda','estimatedSeconds':j['estimatedSeconds']['cuda']},'observations':{'control':'post-preparation deferral'}};q.atomic(attempt/'request.json',request)
 with (out/f'defer-{trial}.log').open('w') as log:
  child=subprocess.Popen([sys.executable,str(out/'defer-worker.py'),'_worker',str(root),key,a],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  assert child.wait(timeout=120)==0
 result=q.read(attempt/'result.json');assert result['status']=='deferred',result
 state=q.case_state(root,c,j);assert state['preparationCache'];time.sleep(2.1)
 def no_mac(_):raise AssertionError('cached-only controller queried Mac GPU capacity')
 start=time.perf_counter()
 with patch.object(q,'mac_snapshot',side_effect=no_mac):assert q.run_queue(root,poll=.1,max_seconds=120)==0
 elapsed=time.perf_counter()-start
 state=q.case_state(root,c,j);assert state['status']=='accepted' and state['attempts']==2
 receipt=q.object_receipt(root,state['object'],c,j);assert receipt['timings']['preparationCacheHit']
 assert receipt['comparison']['passed']
 assert q.run_queue(root,once=True)==0
 request2=q.read(root/'cases'/key/'attempts'/receipt['attempt']/'request.json');assert request2['decision']['preparationCache']
 if trial:assert request2['decision']['estimatedSeconds']==j['cachedCudaEstimatedSeconds']
 else:q.atomic(out/'cached-cost.json',{'workerBodySeconds':receipt['totalSecondsBeforePublication'],'scope':'One cached retry worker body, before publication; excludes controller, not a complete cost calibration','receipt':receipt,'queue':str(root)})
 record['trials'].append(dict(trial=trial,controllerSeconds=elapsed,deferral=result,receipt=receipt,decision=request2['decision'],state=state));q.atomic(out/'study.json',record);print('accepted cached retry',trial,elapsed,flush=True)
record['status']='complete';q.atomic(out/'study.json',record)
