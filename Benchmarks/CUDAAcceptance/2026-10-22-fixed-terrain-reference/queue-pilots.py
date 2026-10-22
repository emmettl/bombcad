"""Queue lock-refused pilots once, retain refusals and compare all returned outcomes."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import os

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')
HERE=Path(__file__).resolve().parent

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def main():
    run=json.loads((ROOT/'run.json').read_text());assert run['status']=='complete-all-outcomes'
    assert len(run['rows'])==3 and all(r['status']=='cuda-failed' for r in run['rows'])
    out=ROOT/'queued-cuda';out.mkdir(exist_ok=False);jobs=[]
    for j in run['jobs']:
        text=(ROOT/'cases'/j['id']/'cuda.log').read_text();assert text.startswith('PC GPU is held by another job')
        remote=re.search(r'bombcad-cuda/[a-f0-9]+/jobs/[a-f0-9]+',text).group(0)
        jobs.append(dict(id=j['id'],remote=remote))
    cfg=dict(jobs=jobs,sourceSHA256=run['generatedSourceSHA256'],lockHelperSHA256=sha(ROOT/'analysis/ml/remote-train.py'),
        workerSHA256={n:sha(ROOT/'analysis/cuda'/n) for n in ['run.py','job.py','compile.py','trace_columns.py']})
    for n in ['queue-pilots.py','queued-worker.py']:shutil.copyfile(HERE/n,out/n)
    save(out/'inputs.json',cfg)
    state=dict(status='waiting-or-running',controllerPID=os.getpid(),jobs=jobs,rows=[],scope='Separate queued execution after all initial launches refused the lock before solve. Original refusals retained. No numerical rerun, changed worker or gate.')
    save(out/'run.json',state)
    script=(out/'queued-worker.py').read_text();encoded=base64.b64encode(json.dumps(cfg).encode()).decode()
    command=' '.join(shlex.quote(x) for x in ['bombcad-ml/venv/bin/python','-u','-c',script,encoded])
    with (out/'remote.log').open('w') as log:
        child=subprocess.Popen(['ssh','-o','BatchMode=yes','bombcad-pc',command],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        state['sshPID']=child.pid;save(out/'run.json',state);code=child.wait()
    state['remoteReturncode']=code
    assert code==0,'queued remote wrapper failed; preserve logs and inspect, never restart automatically'
    line=next(s for s in (out/'remote.log').read_text().splitlines() if s.startswith('QUEUED_PILOT_RESULT '));outcomes=json.loads(line.split(' ',1)[1])
    spec=importlib.util.spec_from_file_location('fixed_compare',ROOT/'analysis/cuda/compare_dataset.py');compare=importlib.util.module_from_spec(spec);spec.loader.exec_module(compare)
    for result in outcomes:
        row=dict(result,eligible=False,status='cuda-failed')
        if result['returncode']==0:
            dest=out/result['id'];dest.mkdir()
            for remote,target in [('out/dataset',dest/'dataset'),('out/result.json',dest/'result.json')]:subprocess.run(['scp','-r','bombcad-pc:'+result['remote']+'/'+remote,str(target)],check=True)
            report=json.loads((dest/'result.json').read_text());assert report['sourceSHA256']==cfg['sourceSHA256']
            assert report['workerFilesSHA256']=={n:cfg['workerSHA256'][n] for n in ['run.py','job.py','compile.py']}
            comparison=compare.compare(ROOT/'cases'/result['id']/'metal',dest/'dataset');row.update(status='compared',eligible=comparison['passed'],comparison=comparison)
        state['rows'].append(row);save(out/'run.json',state)
    state['status']='complete-all-outcomes';state['allPilotsPass']=len(state['rows'])==3 and all(r['eligible'] for r in state['rows']);save(out/'run.json',state)

if __name__=='__main__':main()
