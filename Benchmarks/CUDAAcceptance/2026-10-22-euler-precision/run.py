"""Immutable CPU staging; all 54 declared runs retained, at most two reference workers active."""
from pathlib import Path
import concurrent.futures,hashlib,importlib.util,json,os,platform,shutil,subprocess,sys,threading
import numpy as np
repo=Path.cwd();here=Path(__file__).resolve().parent
sys.path.insert(0,str(repo/'Scripts/cuda'))
spec=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
root=Path(os.environ.get('BOMBCAD_DATA','/Volumes/StudioData/bombcad'))/'experiments/2026-10-22-euler-precision';root.mkdir(parents=True,exist_ok=False)
(root/'sources').mkdir();(root/'inputs').mkdir();(root/'outputs').mkdir()
sources=[repo/'Scripts/reference/planar_euler.py',repo/'Scripts/reference/test-planar-euler.py',here/'worker.py',Path(__file__).resolve(),here/'plan.md',repo/'Sources/BlastCore/Shaders/Solver.metal',repo/'Sources/BlastCore/Shaders/SolverSweep.metal']
pins=[]
for p in sources:
 dst=root/'sources'/p.name;shutil.copy2(p,dst);pins.append(dict(original=str(p),frozen=str(dst),sha256=q.digest(dst)))
previous=json.loads((repo/'Benchmarks/CUDAAcceptance/2026-10-22-acoustic-controls/results.json').read_text());oldroot=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-acoustic-controls');input_pins={};jobs=[]
for cfl in ['0.45','0.225']:
 for amp in [1,10,100]:
  for nx in [512,1024,2048]:
   label=f'a{amp}-n{nx}-cfl{cfl}';base=oldroot/('default-cfl'+cfl);name=f'a{amp}-n{nx}-full'
   pair=[]
   for suffix in ['-plain.json','-trace.json']:
    path=base/(name+suffix);relative=str(path.relative_to(oldroot));h=previous['rawReceipt']['retainedFiles'][relative]['sha256'];assert q.digest(path)==h;input_pins[str(path)]=h;pair.append(json.loads(path.read_text()))
   plain,trace=pair;initial=np.asarray(plain['initialConservedRhoMxEnergy'],dtype=np.float32);values=np.asarray(trace['values'],dtype=np.float32)
   assert initial.shape==(nx,3) and trace['complete'] and plain['stable']
   inp=root/'inputs'/(label+'.npz');np.savez_compressed(inp,initial=initial,dt=values[:,0,6],metalPressurePa=values[:,:,0],metalTimes=np.asarray(trace['times']),indices=np.asarray(trace['columns']),x=np.asarray(trace['x']))
   meta=dict(label=label,amplitudePa=amp,nx=nx,dx=trace['dx'],gamma=float(np.float32(plain['gamma'])),cfl=cfl,sourceHashes={str(base/(name+s)):input_pins[str(base/(name+s))] for s in ['-plain.json','-trace.json']},analyticPeak=trace['analyticPeak'],analyticImpulse=trace['analyticFirstImpulse'])
   inp.with_suffix('.json').write_text(json.dumps(meta,indent=2)+'\n')
   for mode in ['float32-retained','float64-retained','float64-analytic']:jobs.append(dict(label=label,mode=mode,input=str(inp),output=str(root/'outputs'/(label+'-'+mode))))
runtime=dict(platform=platform.platform(),machine=platform.machine(),python=sys.version,executable=sys.executable,pythonSHA256=q.digest(Path(sys.executable).resolve()),numpy=np.__version__,numpyCore=str(np._core._multiarray_umath.__file__),numpyCoreSHA256=q.digest(Path(np._core._multiarray_umath.__file__)))
report=dict(status='running',scope=__doc__,revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),worktreeDirty=True,pid=os.getpid(),runtime=runtime,sources=pins,inputSourceSHA256=input_pins,jobs=jobs,live={})
lock=threading.RLock()
def save():
 with lock:q.atomic(root/'run.json',report)
save()
(root/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary']))
def execute(job):
 env=dict(os.environ,OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1',PYTHONPYCACHEPREFIX=str(root/'pycache'))
 command=[sys.executable,str(root/'sources/worker.py'),job['input'],job['mode'],job['output']]
 with (root/'outputs'/(job['label']+'-'+job['mode']+'.log')).open('wb') as log:
  child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env,start_new_session=True)
  identity=q.process_snapshot(child.pid)
  live=dict(pid=child.pid,pgid=child.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None)
  with lock:
   job['command']=command;report['live'][job['label']+'-'+job['mode']]=live;save()
  code=child.wait();assert not q.group_alive(child.pid),'owned descendant remains live'
 return dict(job=job,returncode=code,terminalProcess=live)
try:
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
  futures={pool.submit(execute,job):job for job in jobs}
  for future in concurrent.futures.as_completed(futures):
   result=future.result();job=futures[future]
   with lock:
    job.update({k:v for k,v in result.items() if k!='job'});report['live'].pop(job['label']+'-'+job['mode']);save()
 report['status']='complete' if all(x.get('returncode')==0 for x in jobs) else 'failed'
 for p in pins:assert q.digest(Path(p['frozen']))==p['sha256']
except BaseException as error:report['status']='failed';report['error']=repr(error);raise
finally:
 report['retainedFiles']={str(p.relative_to(root)):dict(sha256=q.digest(p),bytes=p.stat().st_size) for p in sorted(root.rglob('*')) if p.is_file() and p.name!='run.json' and 'pycache' not in p.relative_to(root).parts}
 save()
assert report['status']=='complete'
print(json.dumps(dict(status=report['status'],jobs=len(jobs),root=str(root),runtime=runtime),indent=2))
