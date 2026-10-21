"""Plain/recorder-only/consumed-pressure controls; no performance or admission-policy claim."""
from pathlib import Path
import hashlib,importlib.util,json,os,subprocess,sys
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'))
s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
s=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(s);s.loader.exec_module(phase)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2');root.mkdir(parents=True,exist_ok=False)
exe=Path('.build/release/scenebench').resolve();slot=str(Path.home()/'.local/bin/gpu-slot');env=q.clean_env(dict(slotEnvironment={},revisionObservedAtInit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),worktreeDirtyAtInit=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip())))
paths=[exe,Path(__file__).resolve(),*sorted((repo/'Sources/BlastCore').rglob('*.swift')),*sorted((repo/'Sources/BlastCore/Shaders').glob('*.metal')),*sorted((repo/'Sources/SceneBench').glob('*.swift')),*sorted((repo/'Sources/BlastModel').rglob('*.swift')),*sorted((repo/'Scripts/cuda').glob('*.py'))]
paths += [p for b in exe.parent.glob('*.bundle') for p in b.rglob('*.metal')]
pins={str(p):q.digest(p) for p in paths};report=dict(status='running',scope=__doc__,pid=os.getpid(),executable=str(exe),revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),sourceFilesSHA256=pins,commands=[],cases=[],failures=[])
(root/'candidate.patch').write_bytes(subprocess.check_output(['git','diff','--binary']))
def save():q.atomic(root/'study.json',report)
def verify():
 for n,h in pins.items():assert q.digest(n)==h,'Source/input changed during study: '+n

def run(args,label,expected=0):
 with (root/(label+'.log')).open('wb') as log:
  command=[slot,'--mem','3',str(exe),'field-export',*args];p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
  identity=q.process_snapshot(p.pid);live=dict(pid=p.pid,pgid=p.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,label=label,command=command)
  report['liveProcess']=live;save();code=p.wait()
 assert not q.group_alive(p.pid),'owned descendant remains live'
 report['commands'].append(dict(**live,returncode=code));report.pop('liveProcess');save();verify()
 if expected==0:assert code==0,(label,code)
 else:assert code!=0,(label,'expected refusal')

def hashes(folder):return {str(p.relative_to(folder)):q.digest(p) for p in folder.rglob('*.npy')}
def physical(meta):
 args=meta['arguments'];out=[];i=0
 while i<len(args):
  key=args[i];i+=1
  if key in ('--out','--trace-columns','--initial-state-diagnostic','--cuda-source'):i+=1;continue
  if key in ('--phase-timings','--trace-pressure','--diagnostic-state-hashes'):continue
  out.append(key)
  if key not in ('--first-phase','--balloon','--roof'):out.append(args[i]);i+=1
 return out
small=['--osm',str(repo/'Samples/MapBuildings/synthetic-neighbourhood.geojson'),'--centre','0.00045,51.50028','--radius','48','--dx','2','--height','32','--mass','10','--until','0.08','--above','1','--ground','saturated','--first-phase','--levels','6,10','--roof','--id','pressure-layers']
cases=[dict(name='small-layers',arguments=small,columns=None,reference=None),
 dict(name='terrain',reference='/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs/made-perimeter-s3-1',columns=[134058,250097]),
 dict(name='beirut',reference='/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs/beirut-p0-1',columns=[159267,159777,159779,164452,200270,255969]),
 dict(name='flat-half',reference='/Volumes/StudioData/bombcad/experiments/2026-10-21-distinct-queue/flat-m100400/reference',columns=[62902])]
report['predeclaredCases']=cases;save()
try:
 for case in cases:
  name=case['name'];base=root/name;base.mkdir();reference=Path(case['reference']) if case['reference'] else None
  args=case.get('arguments') or physical(q.read(reference/'meta.json'))
  for key in ['--osm','--dem','--heights']:
   if key in args:p=Path(args[args.index(key)+1]);pins[str(p)]=q.digest(p)
  if reference:
   for p in reference.iterdir():
    if p.is_file():pins[str(p)]=q.digest(p)
  row=dict(name=name,arguments=args,reference=str(reference) if reference else None,variants=[]);report['cases'].append(row);save()
  for mode in ['plain','legacy','pressure']:
   out=base/mode
   selected=case['columns']
   if mode=='legacy':
    plane=row['variants'][0]['meta']['rows']*row['variants'][0]['meta']['columns'];selected=[i for i in selected if i<plane]
   extra=[] if mode=='plain' else ['--trace-columns',','.join(map(str,selected))]
   if mode=='pressure':extra+=['--trace-pressure']
   run([*args,*extra,'--diagnostic-state-hashes','--out',str(out)],name+'-'+mode)
   item=dict(mode=mode,filesSHA256=hashes(out),stateHashes=q.read(out/'diagnostic-state-hashes.json'),meta=q.read(out/'meta.json'));row['variants'].append(item);save()
   if mode=='plain' and case['columns'] is None:
    shape,mask=q.npy(out/'mask.npy');valid=[i for i,v in enumerate(mask) if v];indices=[valid[len(valid)//3],valid[2*len(valid)//3]]
    levelshape,mask=q.npy(out/'levels-mask.npy');plane=shape[-1]*shape[-2]
    for layer in range(levelshape[0]):
     valid=[i for i,v in enumerate(mask[layer*plane:(layer+1)*plane]) if v]
     if valid:indices.append((layer+1)*plane+valid[len(valid)//2])
    case['columns']=indices;row['columns']=indices;save()
  plain,legacy,pressure=row['variants']
  # Only exported dataset arrays participate, not the intentionally different trace payloads.
  names=[n for n in plain['filesSHA256'] if not n.endswith('trace.npy')]
  row['arrayParity']=all(plain['filesSHA256'][n]==legacy['filesSHA256'][n]==pressure['filesSHA256'][n] for n in names)
  row['initialAndFinalStateParity']=plain['stateHashes']==legacy['stateHashes']==pressure['stateHashes']
  m,d=phase.load(base/'pressure');summary=phase.summarize(m,d);q.atomic(base/'pressure'/'replay.json',summary)
  policies=set(['separate','fused'])
  for c in summary['columns']:policies.intersection_update(c['exactAccumulationPolicies'])
  row['wholeTraceExactAccumulationPolicies']=sorted(policies)
  lm=q.read(base/'legacy/production-trace.json');shape,legacy_values=q.npy(base/'legacy/production-trace.npy');columns=lm['columns'];count=len(m['columns']);column_q={n:i for i,n in enumerate(m['columns'])}
  row['recorderHistoryParity']=lm['steps']==m['steps'][1:] and lm['times']==m['times'][1:] and all(
   list(legacy_values[(step*len(columns)+qcol)*8:(step*len(columns)+qcol)*8+5])==list(d[((step+1)*count+column_q[column])*8+1:((step+1)*count+column_q[column])*8+6])
   for step in range(shape[0]) for qcol,column in enumerate(columns))
  row['historicalArraysBitIdentical']=all(q.digest(reference/n)==q.digest(base/'plain'/n) for n in q.DATA_FILES if n!='meta.json') if reference else None
  row['unmodifiedProductionParity']=row['arrayParity'] and row['initialAndFinalStateParity'] and row['recorderHistoryParity'];q.atomic(base/'validation.json',row);save();print(name,'parity',row['unmodifiedProductionParity'],'replay',row['wholeTraceExactAccumulationPolicies'],flush=True)
 for label,extra in [('missing-columns',['--trace-pressure']),('missing-budget',['--trace-pressure','--trace-columns',str(cases[0]['columns'][0]),'--trace-pressure-max-samples']),('budget-overflow',['--trace-pressure','--trace-columns',str(cases[0]['columns'][0]),'--trace-pressure-max-samples','2'])]:
  dest=root/('refused-'+label);run([*small,*extra,'--out',str(dest)],'refused-'+label,expected=1);assert not dest.exists()
  report['failures'].append(dict(case=label,noOutputWritten=True));save()
 report.update(status='complete',allOwnedGroupsTerminal=True,allCasesPassParity=all(c['unmodifiedProductionParity'] for c in report['cases']));save()
except BaseException as e:report.update(status='failed',error=repr(e));save();raise
