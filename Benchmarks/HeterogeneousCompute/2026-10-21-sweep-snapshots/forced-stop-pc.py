"""Only synthetic local children: force-stop must retain ownership until the group is dead."""
import hashlib,importlib.util,json,os,signal,subprocess,sys,tempfile,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('sweep',Path('Scripts/remote-sweep.py').resolve());m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as folder:
 lock=Path(folder)/'lock'
 child="import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"
 code=f'''import importlib.util,subprocess,os,sys
s=importlib.util.spec_from_file_location('sweep',{m.__file__!r}); m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.prepare_worker();os.mkdir({str(lock)!r});m.atomic_json({str(lock/'owner')!r},dict(pid=os.getpid(),pgid=os.getpgrp(),boot='forced-control'))
p=subprocess.Popen([sys.executable,'-c',{child!r}],stdout=subprocess.PIPE,text=True)
print(p.stdout.readline().strip(),flush=True)
try:p.wait()
finally:m.release_sweep({str(lock)!r})
'''
 worker=subprocess.Popen([sys.executable,'-c',code],stdout=subprocess.PIPE,text=True,start_new_session=True)
 try:
  assert worker.stdout.readline().strip()=='ready';os.kill(worker.pid,signal.SIGTERM);worker.wait(timeout=10)
  assert worker.returncode==-signal.SIGKILL and lock.exists()
  deadline=time.monotonic()+5
  while m.group_members(worker.pid) and time.monotonic()<deadline:time.sleep(.01)
  assert not m.group_members(worker.pid);assert m.sweep_owner(str(lock),'forced-control') is None;assert not lock.exists()
  print(json.dumps(dict(status='complete',runnerSHA256=hashlib.sha256(Path(m.__file__).read_bytes()).hexdigest(),workerReturncode=worker.returncode,lockRetainedAfterForcedStop=True,staleRecoveryOnlyAfterGroupDeath=True,scope='Synthetic PC group only; no production job targeted.'),indent=2))
 finally:
  try:os.killpg(worker.pid,signal.SIGKILL)
  except ProcessLookupError:pass
  worker.wait(timeout=5);worker.stdout.close()
