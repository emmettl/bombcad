"""One retained-case CUDA trace, with full remote numeric-file/dt parity; no benchmark or admission."""
from pathlib import Path
import importlib.util,json,os,shlex,subprocess,sys
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
s=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(s);s.loader.exec_module(phase)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2');state=root/'cuda-flat.json';assert not state.exists()
job=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-distinct-queue/flat-m100400/prepared');old=q.read(job.parent/'cuda/deployment.json')['directory'];out=root/'flat-half/cuda-trace'
r=dict(status='running',scope=__doc__,pid=os.getpid(),job=str(job),sourceFileSHA256=q.digest(Path(__file__)),before=q.pc_snapshot(dict(cuda={'host':'bombcad-pc'})))
def save():q.atomic(state,r)
save()
try:
 assert r['before']['available'],'PC unavailable: no CUDA deployment started'
 command=[sys.executable,str(repo/'Scripts/cuda/remote.py'),'bombcad-pc',str(job),'--out',str(out),'--trace-columns','62902','--diagnostics-only','--cache-dir','bombcad-cuda/ptx-cache']
 with (root/'cuda-flat.log').open('wb') as log:
  p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True);identity=q.process_snapshot(p.pid);r['liveProcess']=dict(pid=p.pid,pgid=p.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,command=command);save();code=p.wait()
 assert not q.group_alive(p.pid);r['command']=dict(**r.pop('liveProcess'),returncode=code);save();assert code==0
 deployment=q.read(out/'deployment.json');new=deployment['directory']
 script="""import pathlib,hashlib,json
root=pathlib.Path.home()
def files(name):
 p=root/name/'out';return {str(q.relative_to(p)):hashlib.sha256(q.read_bytes()).hexdigest() for q in sorted(p.rglob('*')) if q.is_file() and q.suffix in ('.bin','.npy')}
a=files(OLD);b=files(NEW);assert a and all(b.get(k)==v for k,v in a.items());assert set(b)-set(a)=={'trace.npy'};print(json.dumps(dict(status='complete',baselineDirectory=OLD,tracedDirectory=NEW,baseline=a,traced=b,boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip())))
""".replace('OLD',repr(old)).replace('NEW',repr(new))
 proof=json.loads(subprocess.check_output(['ssh','-o','BatchMode=yes','bombcad-pc','python3 -c '+shlex.quote(script)],text=True));q.atomic(root/'cuda-flat-numeric-proof.json',proof)
 meta,data=phase.load(out);summary=phase.summarize(meta,data);assert len(summary['columns'])==1 and summary['columns'][0]['float32Replay']['recorderValuesDifferent']==0;q.atomic(out/'replay.json',summary)
 r.update(status='complete',deployment=deployment,fullRemoteNumericFilesAndTimestepsBitIdentical=True,baselineNumericFileCount=len(proof['baseline']),after=q.pc_snapshot(dict(cuda={'host':'bombcad-pc'})));save();print(json.dumps(r,indent=2))
except BaseException as e:r.update(status='failed',error=repr(e));save();raise
