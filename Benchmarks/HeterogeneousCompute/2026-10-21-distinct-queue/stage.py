"""Predeclared distinct full-flat workload admission stage; not a throughput benchmark or training publication."""
from pathlib import Path
import hashlib,importlib.util,json,os,subprocess,sys,time
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'))
s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
from generate import generate
from job import validate
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-distinct-queue');root.mkdir(parents=True,exist_ok=False)
exe=Path('.build/release/scenebench').resolve();slot=str(Path.home()/'.local/bin/gpu-slot');original=Path('/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs/made-perimeter-s1-1')
context=dict(cuda={'host':'bombcad-pc'},gpuSlot=slot,slotEnvironment={},revisionObservedAtInit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),worktreeDirtyAtInit=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()))
env=q.clean_env(context);source=generate();(root/'solver.cu').write_text(source)
files=[Path(__file__).resolve(),exe,original/'meta.json',*sorted((repo/'Sources/BlastCore').rglob('*.swift')),*sorted((repo/'Sources/BlastCore/Shaders').glob('*.metal')),*sorted((repo/'Sources/SceneBench').glob('*.swift')),*sorted((repo/'Scripts/cuda').glob('*.py')),repo/'Scripts/cuda/entry.cuh',repo/'Scripts/cuda/compat.cuh']
files += [p for b in exe.parent.glob('*.bundle') for p in b.rglob('*.metal')]
pins={str(p):q.digest(p) for p in files}
report=dict(status='running',scope=__doc__,pid=os.getpid(),root=str(root),context=context,executable=str(exe),filesSHA256=pins,sourceSHA256=hashlib.sha256(source.encode()).hexdigest(),fixedMassesKg=[100400,200800,301200],cases=[],commands=[])
def save():q.atomic(root/'stage.json',report)
def verify():
 for n,h in pins.items():assert q.digest(n)==h,'Source/input changed: '+n
def run(command,label):
 p=subprocess.Popen(command,stdout=(root/(label+'.log')).open('wb'),stderr=subprocess.STDOUT,start_new_session=True,env=env)
 identity=q.process_snapshot(p.pid);live=dict(pid=p.pid,pgid=p.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,label=label,command=command)
 report['liveProcess']=live;save();code=p.wait();assert not q.group_alive(p.pid),'live descendant after child exit'
 report['commands'].append(dict(**live,returncode=code));report.pop('liveProcess');save()
 if code:raise RuntimeError(label+' failed; inspect retained processes/output, never restart on observation timeout')
 verify()
def dataset(folder):return {n:q.digest(folder/n) for n in q.DATA_FILES}
def comparison(a,b):
 try:return q.compare(a,b)
 except ValueError as e:return dict(passed=False,contractError=str(e))
def physical_identity(meta):return {k:meta.get(k) for k in ['shape','uniforms','axes','steps','duration','startTime','startStep','above','startupSteps','cooling','terrain','files']}
save()
try:
 original_meta=q.read(original/'meta.json');args=original_meta['arguments'];physical=[];i=0
 while i<len(args):
  key=args[i];i+=1
  if key=='--out':i+=1;continue
  if key=='--phase-timings':continue
  physical.append(key)
  if key not in ('--first-phase','--balloon'):physical.append(args[i]);i+=1
 for key in ('--osm','--dem','--heights'):
  if key in physical:
   p=Path(physical[physical.index(key)+1]);pins[str(p)]=q.digest(p)
 physical += ['--height',str(original_meta['domainM'][2]),'--until',str(round(original_meta['untilS'],2))]
 report['fixedHeightM']=original_meta['domainM'][2];report['fixedUntilS']=round(original_meta['untilS'],2);report['originalArguments']=args;save()
 for mass in report['fixedMassesKg']:
  label='flat-m'+str(mass);arguments=list(physical);arguments[arguments.index('--mass')+1]=str(mass);arguments[arguments.index('--id')+1]=label
  base=root/label;base.mkdir();row=dict(id=label,massKg=mass,arguments=arguments);report['cases'].append(row);save()
  reference=base/'reference';observed=base/'observed-reference';initial=base/'initial';prepared=base/'prepared';out=base/'cuda'
  run([slot,'--mem','3',str(exe),'field-export',*arguments,'--phase-timings','--out',str(reference)],label+'-reference')
  m=q.read(reference/'meta.json');assert m['stable'] and m['steps']>0;row['reference']=dict(meta=m,filesSHA256=dataset(reference))
  if mass==200800:row['historicalGate']=comparison(original,reference)
  run([slot,'--mem','3',str(exe),'field-export',*arguments,'--initial-state-diagnostic',str(initial),'--cuda-source',str(root/'solver.cu'),'--out',str(observed)],label+'-initial-control')
  row['initialObservationBitIdentical']=all(q.digest(reference/n)==q.digest(observed/n) for n in ['inputs.npy','mask.npy','targets.npy']);assert row['initialObservationBitIdentical']
  im,_=validate(initial,source)
  run([slot,'--mem','3',str(exe),'field-export',*arguments,'--cuda-job','--cuda-source',str(root/'solver.cu'),'--phase-timings','--out',str(prepared)],label+'-prepare')
  pm,_=validate(prepared,source);row['physicalInitialIdentity']=physical_identity(pm);row['initialMatchesPrepared']=physical_identity(im)==physical_identity(pm);assert row['initialMatchesPrepared'];save()
  before=q.pc_snapshot(context);row['pcBefore']=before;save()
  if not before['available']:raise RuntimeError('PC unavailable before dispatch; no worker started for this case. Inspect owner before continuation')
  run([sys.executable,str(repo/'Scripts/cuda/remote.py'),'bombcad-pc',str(prepared),'--out',str(out),'--dataset-only','--cache-dir','bombcad-cuda/ptx-cache'],label+'-cuda')
  row['deployment']=q.read(out/'deployment.json');row['cudaResult']=q.read(out/'result.json');row['cudaDatasetSHA256']=dataset(out/'dataset');row['gate']=comparison(reference,out/'dataset');row['pcAfter']=q.pc_snapshot(context);save();print(label,'gate',row['gate']['passed'],flush=True)
 report.update(status='complete',allDistinctCasesPass=all(c['gate']['passed'] for c in report['cases']),allStartedCommandGroupsTerminal=True,decision='Eligible for separately calibrated mixed backlog only if all three unchanged gates pass. No training publication or throughput claim.');verify();save();print(json.dumps(dict(status=report['status'],allDistinctCasesPass=report['allDistinctCasesPass']),indent=2))
except BaseException as e:report.update(status='failed',error=repr(e));save();raise
