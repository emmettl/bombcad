"""Validate single-owner timekeeping, then commit a reversible guest-client mask."""
import importlib.util,json,os,re,signal,subprocess,time,uuid
from pathlib import Path
root=Path(__file__).resolve().parent;assert os.geteuid()==0
assert Path('/home/lemme/bombcad-pinned-control-01a15d45/inputs.json').exists()
s=importlib.util.spec_from_file_location('lock',root/'remote-train.py');lock=importlib.util.module_from_spec(s);s.loader.exec_module(lock)
lockpath=Path('/home/lemme/bombcad-ml/lock');unit='bombcad-normalize-rollback-'+uuid.uuid4().hex[:12];token=uuid.uuid4().hex
report=dict(status='running',scope=__doc__,pid=os.getpid(),boot=lock.boot_id(),token=token,restoreUnit=unit,samples=[],events=[])
changed=False;guard=False;committed=False;initial=None;started=None

def raw():return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
def save():
 p=root/'experiment.tmp';p.write_text(json.dumps(report,indent=2)+'\n');os.replace(p,root/'experiment.json')
def run(args,check=True):
 p=subprocess.run(args,capture_output=True,text=True,timeout=25)
 if check and p.returncode:raise RuntimeError(str(args)+': '+p.stderr)
 return dict(returncode=p.returncode,stdout=p.stdout,stderr=p.stderr)
def state():return dict(active=run(['systemctl','is-active','systemd-timesyncd.service'],False)['stdout'].strip(),enabled=run(['systemctl','is-enabled','systemd-timesyncd.service'],False)['stdout'].strip(),clocksource=Path('/sys/devices/system/clocksource/clocksource0/current_clocksource').read_text().strip())
def tracking():
 p=subprocess.run(['/mnt/c/Windows/System32/wsl.exe','--system','--user','root','--exec','/usr/bin/chronyc','-n','tracking'],capture_output=True,timeout=25,cwd='/mnt/c');text=p.stdout.decode(errors='replace')
 if p.returncode or 'PHC0' not in text or not re.search(r'Leap status\s*:\s*Normal',text):raise RuntimeError('host agent unhealthy: '+text)
 return text
def event(name,**extra):
 report['events'].append(dict(name=name,rawSeconds=raw()-started,**extra));save();print(json.dumps(report['events'][-1]),flush=True)
def rollback():return run(['/usr/bin/python3',str(root/'rollback.py')])
def stop_guard():
 if guard:
  report['guardStop']=run(['systemctl','stop',unit+'.timer',unit+'.service'],False)
  report['guardTimerAfter']=run(['systemctl','show',unit+'.timer','-p','LoadState','-p','ActiveState'],False)
  assert 'ActiveState=active' not in report['guardTimerAfter']['stdout']
def signal_stop(*_):raise InterruptedError('normalization interrupted; rolling back unless committed')
for sig in [signal.SIGHUP,signal.SIGINT,signal.SIGTERM]:signal.signal(sig,signal_stop)
if not lock.acquire(str(lockpath),'guarded single-owner clock normalization '+token,lock.boot_id()):raise SystemExit('compute lock held')
try:
 owner=lockpath.parent.stat()
 for p in [lockpath,lockpath/'owner']:os.chown(p,owner.st_uid,owner.st_gid)
 started=raw();initial=state();assert initial['active']=='active' and initial['enabled']=='enabled',initial
 target=Path('/etc/systemd/system/systemd-timesyncd.service');assert not target.exists() and not target.is_symlink(),'existing local override'
 report['initial']=initial;report['hostAgentBefore']=tracking();report['gpuBefore']=run(['/usr/lib/wsl/lib/nvidia-smi','--query-gpu=utilization.gpu,memory.used','--format=csv,noheader,nounits']);assert int(report['gpuBefore']['stdout'].split(',')[0])<=5
 (root/'rollback.py').write_text("import subprocess\nsubprocess.run(['systemctl','unmask','systemd-timesyncd.service'],check=True)\nsubprocess.run(['systemctl','enable','--now','systemd-timesyncd.service'],check=True)\n")
 report['phase']='armed';event('armed')
 end=raw()+60
 while not (root/'start.ack').exists():
  if raw()>end:raise TimeoutError('normalization not acknowledged')
  time.sleep(.2)
 assert (root/'start.ack').read_text().strip()==token
 guard=True;report['guardCreate']=run(['systemd-run','--unit='+unit,'--on-active=600s','--timer-property=AccuracySec=1s','--property=Type=oneshot','/usr/bin/python3',str(root/'rollback.py')]);assert run(['systemctl','is-active',unit+'.timer'])['stdout'].strip()=='active'
 changed=True;run(['systemctl','stop','systemd-timesyncd.service']);report['phase']='validation';report['validationStartRawSeconds']=raw()-started;event('guest-client-paused-for-validation')
 end=raw()+520;sample_at=raw()
 while raw()<end:
  if raw()>=sample_at:
   st=state();assert st['active']=='inactive' and st['enabled']=='enabled',st
   d=json.loads(run([str(root/'read-clock-state')])['stdout']);t=tracking();a=raw();mono=time.clock_gettime(time.CLOCK_MONOTONIC);real=time.time();b=raw()
   report['samples'].append(dict(rawSeconds=(a+b)/2-started,rawClock=(a+b)/2,monotonicClock=mono,realtimeClock=real,clockReadHalfWidthSeconds=(b-a)/2,discipline=d,tracking=t,guestState=st));save();sample_at=raw()+15
  if (root/'commit.json').exists():
   decision=json.loads((root/'commit.json').read_text());assert decision['token']==token and decision['accepted'] is True
   report['externalValidation']=decision;run(['systemctl','mask','--now','systemd-timesyncd.service']);stop_guard()
   st=state();assert st==dict(active='inactive',enabled='masked',clocksource=initial['clocksource']),st
   report['hostAgentAfter']=tracking();committed=True;report['phase']='normalized';event('single-owner-policy-committed');break
  time.sleep(.5)
 if not committed:raise TimeoutError('no accepted independent validation within budget')
 report['status']='complete'
except BaseException as error:
 report.update(status='failed',error=repr(error));raise
finally:
 try:
  if changed and not committed:report['rollback']=rollback()
  stop_guard();report['final']=state()
  if initial:
   expected=dict(active='inactive',enabled='masked',clocksource=initial['clocksource']) if committed else initial
   assert report['final']==expected,(report['final'],expected)
  report['policyCommitted']=committed;report['rollbackVerified']=not committed and bool(initial)
 finally:
  report['lockReleased']=lock.release(str(lockpath));report['rawTotalSeconds']=raw()-started if started else None;save();print(json.dumps(dict(status=report['status'],policyCommitted=committed,lockReleased=report['lockReleased'])),flush=True)
