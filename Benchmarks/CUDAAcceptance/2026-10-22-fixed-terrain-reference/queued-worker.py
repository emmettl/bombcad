"""Wait for the existing PC lease, then run unchanged staged workers once."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

cfg=json.loads(base64.b64decode(sys.argv[1]));jobs=cfg['jobs']
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
helper=Path(jobs[0]['remote'])/'worker/remote-train.py'
assert sha(helper)==cfg['lockHelperSHA256']
spec=importlib.util.spec_from_file_location('shared_lock',helper);lock=importlib.util.module_from_spec(spec);spec.loader.exec_module(lock)
for job in jobs:
    root=Path(job['remote']);assert not (root/'out').exists(),'original worker already produced output; refuse replacement'
    for name,pin in cfg['workerSHA256'].items():assert sha(root/'worker'/name)==pin
    assert sha(root/'worker/solver.cu')==cfg['sourceSHA256']
lockpath=str(Path.home()/'bombcad-ml/lock');start=time.monotonic()
while not lock.acquire(lockpath,'fixed-main flat/slope/Beirut CUDA acceptance pilots',lock.boot_id()):
    assert time.monotonic()-start<80*60,'queue budget exceeded without acquiring lock'
    print('Waiting for existing GPU lease:',json.dumps(lock.lock_owner(lockpath,lock.boot_id())),flush=True);time.sleep(30)
rows=[]
try:
    for job in jobs:
        root=Path(job['remote']);command=[sys.executable,str(root/'worker/run.py'),str(root/'input'),'--source',str(root/'worker/solver.cu'),'--out',str(root/'out')]
        print('Starting unchanged staged worker',job['id'],flush=True)
        result=subprocess.run(command)
        rows.append(dict(id=job['id'],remote=job['remote'],returncode=result.returncode))
finally:
    lock.release(lockpath)
print('QUEUED_PILOT_RESULT '+json.dumps(rows),flush=True)
