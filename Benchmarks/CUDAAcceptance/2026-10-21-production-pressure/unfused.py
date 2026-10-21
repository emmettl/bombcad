"""Explicit safe/contract-off small control; no default or admission-policy change."""
from pathlib import Path
import importlib.util,json,os,subprocess,sys
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
s=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(s);s.loader.exec_module(phase)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2');state=root/'unfused.json';assert not state.exists();base=root/'unfused';base.mkdir();study=q.read(root/'study.json');case=study['cases'][0];columns=case['columns'];exe=study['executable'];slot=str(Path.home()/'.local/bin/gpu-slot')
env=q.clean_env(dict(slotEnvironment={},revisionObservedAtInit=study['revision'],worktreeDirtyAtInit=True));env.update(BOMBCAD_KERNEL_MATH='safe',BOMBCAD_KERNEL_CONTRACT='off');r=dict(status='running',scope=__doc__,pid=os.getpid(),math='safe',contract='off',commands=[],variants=[])
def save():q.atomic(state,r)
save()
try:
 for mode in ['plain','pressure']:
  out=base/mode;extra=[] if mode=='plain' else ['--trace-columns',','.join(map(str,columns)),'--trace-pressure'];command=[slot,'--mem','3',exe,'field-export',*case['arguments'],*extra,'--diagnostic-state-hashes','--out',str(out)]
  with (base/(mode+'.log')).open('wb') as log:p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env);r['liveProcess']=dict(pid=p.pid,pgid=p.pid,command=command);save();code=p.wait()
  assert not q.group_alive(p.pid);r['commands'].append(dict(**r.pop('liveProcess'),returncode=code));save();assert code==0
  r['variants'].append(dict(mode=mode,hashes={str(p.relative_to(out)):q.digest(p) for p in out.rglob('*.npy') if not p.name.endswith('trace.npy')},state=q.read(out/'diagnostic-state-hashes.json')));save()
 assert r['variants'][0]['hashes']==r['variants'][1]['hashes'] and r['variants'][0]['state']==r['variants'][1]['state']
 m,d=phase.load(base/'pressure');summary=phase.summarize(m,d);assert all(c['float32Replay']['recorderValuesDifferent']==0 for c in summary['columns']);q.atomic(base/'pressure/replay.json',summary)
 r.update(status='complete',arraysAndCompleteCoarseStateParity=True,wholeTraceSeparateAccumulationExact=True,allOwnedGroupsTerminal=True);save();print(json.dumps(r,indent=2))
except BaseException as e:r.update(status='failed',error=repr(e));save();raise
