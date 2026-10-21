"""Additional-case/grid arithmetic sensitivity; numerical diagnostics, never performance or admission."""
import hashlib,importlib.util,json,os,subprocess,sys,time
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
from generate import generate
from job import validate
import remote
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-independent-portability');root.mkdir(parents=True,exist_ok=False)
exe=Path('.build/release/scenebench').resolve();slot='/Users/louisemmett/.local/bin/gpu-slot';revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
context=dict(slotEnvironment={k:os.environ[k] for k in q.SLOT_ENV if k in os.environ},revisionObservedAtInit=revision,worktreeDirtyAtInit=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()))
env=q.clean_env(context);source=generate();(root/'solver.cu').write_text(source)
observed=sorted((repo/'Sources/BlastCore').rglob('*.swift'))+sorted((repo/'Sources/BlastCore/Shaders').glob('*.metal'))+sorted((repo/'Sources/SceneBench').glob('*.swift'))+sorted((repo/'Sources/BlastModel').glob('*.swift'))
resources=[p for b in exe.parent.glob('*.bundle') for p in b.rglob('*.metal')]
pins={str(p):q.digest(p) for p in [exe,*observed,*resources,repo/'Scripts/cuda/run.py',repo/'Scripts/cuda/job.py',repo/'Scripts/cuda/compile.py',repo/'Scripts/cuda/generate.py',repo/'Scripts/cuda/entry.cuh',repo/'Scripts/cuda/compat.cuh']}
report=dict(status='running',scope=__doc__,revisionObserved=revision,worktreeDirty=context['worktreeDirtyAtInit'],executable=str(exe),filesSHA256=pins,cudaSourceSHA256=hashlib.sha256(source.encode()).hexdigest(),groups=[])
def save():q.atomic(root/'study.json',report)
def verify():
 for name,h in pins.items():assert q.digest(name)==h,('source/runtime changed',name)
 assert generate()==source

def run(command,label,environment):
 p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,env=environment)
 identity=q.process_snapshot(p.pid);q.atomic(root/'live-process.json',dict(pid=p.pid,pgid=p.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,label=label,command=command))
 # An observation timeout leaves this same process alive for inspection; never relaunch on timeout.
 data,_=p.communicate(timeout=1200);(root/(label+'.log')).write_bytes(data)
 if p.returncode:raise RuntimeError('command failed '+label+': '+str(p.returncode))
 if q.group_alive(p.pid):raise RuntimeError('descendant remains live after '+label)
 verify()

def files(folder):return {n:q.digest(folder/n) for n in q.DATA_FILES}
def comparison(reference,folder):
 try:return q.compare(reference,folder)
 except ValueError as error:return dict(passed=False,contractError=str(error))

save()
try:
 for original,height,short in [('made-perimeter-s1-1',240,'flat'),('made-perimeter-s3-1',200,'terrain')]:
  legacy=Path('/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs')/original;meta=q.read(legacy/'meta.json');pins[str(legacy/'meta.json')]=q.digest(legacy/'meta.json');physical=[];i=0
  while i<len(meta['arguments']):
   key=meta['arguments'][i];i+=1
   if key in ['--out','--phase-timings']:
    if key=='--out':i+=1
    continue
   physical.append(key)
   if key not in ('--first-phase','--balloon'):physical.append(meta['arguments'][i]);i+=1
  for dx in [4,8]:
   name=f'{short}-h{height}-dx{dx}';base=root/name;base.mkdir();args=list(physical);args[args.index('--dx')+1]=str(dx);args[args.index('--id')+1]=name
   if '--height' in args:args[args.index('--height')+1]=str(height)
   else:args+=['--height',str(height)]
   input_pins={args[i+1]:q.digest(args[i+1]) for i,v in enumerate(args[:-1]) if v in ['--osm','--dem','--heights']};pins.update(input_pins)
   group=dict(name=name,originalCase=original,dx=dx,height=height,arguments=args,inputSHA256=input_pins,variants=[]);report['groups'].append(group);save()
   reference=base/'plain-reference';run([slot,'--mem','3',str(exe),'field-export',*args,'--out',str(reference)],name+'-default-tiled',env)
   m=q.read(reference/'meta.json');assert m['stable'] and m['steps']>0 and m['domainM']==[2048,2048,height]
   shape,values=q.npy(reference/'targets.npy');_,mask=q.npy(reference/'mask.npy');plane=shape[1]*shape[2]
   assert max(values[:plane])>100
   group['reference']=dict(metadata=m,filesSHA256=files(reference),validTargetsPerChannel=sum(bool(v) for v in mask),maxPeakPa=max(values[:plane]));pins.update({str(reference/n):q.digest(reference/n) for n in q.DATA_FILES})
   modes=[('default',None,None),('fast-on','fast','on'),('fast-off','fast','off'),('safe-on','safe','on'),('safe-off','safe','off')]
   for mode,math,contract in modes:
    e=dict(env)
    if math is not None:e['BOMBCAD_KERNEL_MATH']=math
    if contract is not None:e['BOMBCAD_KERNEL_CONTRACT']=contract
    for path in ['tiled','full']:
     folder=base/(mode+'-'+path)
     initial=base/(mode+'-'+path+'-initial');extra=['--full-grid-diagnostic'] if path=='full' else []
     run([slot,'--mem','3',str(exe),'field-export',*args,*extra,'--initial-state-diagnostic',str(initial),'--cuda-source',str(root/'solver.cu'),'--out',str(folder)],name+'-'+mode+'-'+path,e)
     initial_meta,_=validate(initial,source)
     initial_keys=['shape','uniforms','axes','steps','duration','startTime','startStep','above','startupSteps','cooling','terrain','files']
     initial_identity={k:initial_meta.get(k) for k in initial_keys}
     if mode=='default' and path=='tiled':
      group['observerArraysBitIdentical']=all(q.digest(reference/n)==q.digest(folder/n) for n in ['inputs.npy','mask.npy','targets.npy'])
      assert group['observerArraysBitIdentical'],'Initial snapshot changes production output'
      group['baselineInitial']=initial_identity
     assert q.read(folder/'meta.json')['stable']
     item=dict(mode=mode,path=path,initialState=initial_identity,initialMatchesDefault=initial_identity==group['baselineInitial'],environment={k:e.get(k) for k in q.PROBES},filesSHA256=files(folder),comparisonToDefaultTiled=comparison(reference,folder));group['variants'].append(item);save();print('variant',name,mode,path,item['comparisonToDefaultTiled'].get('0',{}).get('outsideTolerance'),flush=True)
   group['withinModeTiledFull']={mode:dict(arraysBitIdentical=all(q.digest(base/(mode+'-tiled')/n)==q.digest(base/(mode+'-full')/n) for n in ['inputs.npy','mask.npy','targets.npy']),comparison=comparison(base/(mode+'-tiled'),base/(mode+'-full'))) for mode,_,_ in modes};save()
   prepared=base/'cuda-input';run([slot,'--mem','3',str(exe),'field-export',*args,'--cuda-job','--cuda-source',str(root/'solver.cu'),'--out',str(prepared)],name+'-prepare',env)
   validate(prepared,source)
   pc=q.pc_snapshot({'cuda':{'host':'bombcad-pc'}});group['pcBefore']=pc;save()
   if not pc['available']:raise RuntimeError('PC reserved/unavailable; preserve prepared input and observe owner before continuation')
   out=base/'cuda-result';result=remote.deploy('bombcad-pc',prepared,out,dataset_only=True,cache_dir='bombcad-cuda/ptx-cache');verify()
   group['cuda']=dict(result=result,deployment=q.read(out/'deployment.json'),filesSHA256=files(out/'dataset'),comparisonToDefaultTiled=comparison(reference,out/'dataset'))
   for mode,_,_ in modes:group['cuda'][mode+'Comparison']=comparison(base/(mode+'-tiled'),out/'dataset')
   save();print('cuda',name,group['cuda']['comparisonToDefaultTiled']['passed'],flush=True)
 report['status']='complete';save()
except BaseException as error:report.update(status='failed',error=repr(error));save();print('Inspect same live-process/remote lock after an observation failure; do not restart jobs merely because observation expired.',flush=True);raise
