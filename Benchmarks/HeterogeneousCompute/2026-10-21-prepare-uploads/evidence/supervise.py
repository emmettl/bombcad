"""Periodic read-only ownership/resource observations around one existing-lock profiler run."""
from pathlib import Path
import json,os,subprocess,time,sys
root=Path(__file__).resolve().parent;label=sys.argv[1];variant=sys.argv[2];jobs=sys.argv[3:];state=root/(label+'-state.json');samples=[];p=None
interval=3 if any(j in ['flat512','beirut512'] for j in jobs) else 1
def probe(args):
 try:
  p=subprocess.run(args,capture_output=True,text=True,timeout=10);return dict(returncode=p.returncode,stdout=p.stdout,stderr=p.stderr)
 except subprocess.TimeoutExpired:return dict(observationTimedOut=True)
def sample():
 lock=Path.home()/'bombcad-ml/lock/owner'
 try:owner=json.loads(lock.read_text())
 except (OSError,ValueError):owner=None
 processes=probe(['nvidia-smi','--query-compute-apps=pid,process_name,used_memory','--format=csv']);observed=[]
 for line in processes.get('stdout','').splitlines()[1:]:
  try:pid=int(line.split(',')[0].strip())
  except ValueError:continue
  entry=dict(pid=pid)
  try:
   entry.update(pgid=os.getpgid(pid),command=Path('/proc',str(pid),'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace'))
   entry['ownedGroup']=p is not None and entry['pgid']==p.pid
  except ProcessLookupError:entry['exitedBeforeGroupRead']=True
  except FileNotFoundError:entry['exitedBeforeGroupRead']=True
  observed.append(entry)
 return dict(rawSeconds=time.clock_gettime(time.CLOCK_MONOTONIC_RAW),owner=owner,gpu=probe(['nvidia-smi','--query-gpu=name,driver_version,memory.used,utilization.gpu','--format=csv']),processes=processes,observed=observed)
cmd=[str(Path.home()/'bombcad-ml/venv/bin/python'),str(root/'profile-worker.py'),'--baseline',str(root/'baseline.py'),'--candidate',str(root/variant),'--source',str(root/'solver.cu'),'--jobs',*[str(root/j) for j in jobs],'--out',str(root/label),'--lock',str(Path.home()/'bombcad-ml/lock'),'--lock-helper',str(root/'remote-train.py'),'--baseline-cache-dir',str(Path.home()/'bombcad-cuda/ptx-cache'),'--candidate-cache-dir',str(Path.home()/'bombcad-cuda/ptx-cache'),'--fresh-process']
samples.append(sample());assert samples[-1]['owner'] is None,'existing GPU lease; no job started'
assert not samples[-1]['observed'],'existing compute process; no job started'
assert int(samples[-1]['gpu']['stdout'].strip().splitlines()[-1].split(',')[-1].strip().split()[0])==0,'GPU is active; no job started'
with (root/(label+'.log')).open('wb') as out:
 p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 report=dict(status='running',pid=p.pid,pgid=p.pid,command=cmd,sampleIntervalSeconds=interval,samples=samples);state.write_text(json.dumps(report,indent=2)+'\n')
 while p.poll() is None:
  time.sleep(interval);samples.append(sample());state.write_text(json.dumps(report,indent=2)+'\n')
 report.update(status='complete' if p.returncode==0 else 'failed',returncode=p.returncode);samples.append(sample());report['externalComputeGroupObserved']=any(x.get('ownedGroup') is False for sample in samples for x in sample.get('observed',[]));state.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(label=label,status=report['status'],returncode=p.returncode,samples=len(samples))))
sys.exit(p.returncode)
