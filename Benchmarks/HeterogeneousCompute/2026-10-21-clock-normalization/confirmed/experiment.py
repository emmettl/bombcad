"""Bounded A/B/A clock-controller test; pause guest client only and restore its state."""
import importlib.util,json,os,re,signal,subprocess,time,uuid
from pathlib import Path
root=Path(__file__).resolve().parent;assert os.geteuid()==0
assert Path('/home/lemme/bombcad-pinned-control-01a15d45/inputs.json').exists()
spec=importlib.util.spec_from_file_location('lock',root/'remote-train.py');lock=importlib.util.module_from_spec(spec);spec.loader.exec_module(lock)
lockpath=Path('/home/lemme/bombcad-ml/lock');unit='bombcad-clock-restore-'+uuid.uuid4().hex[:12];token=uuid.uuid4().hex
report=dict(status='running',scope=__doc__,pid=os.getpid(),boot=lock.boot_id(),token=token,restoreUnit=unit,samples=[],events=[])
need_restore=False;watchdog=False;initial=None;started=None

def raw():return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)
def atomic(path,value):
 temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value,indent=2)+'\n');os.replace(temp,path)
def save():atomic(root/'experiment.json',report)
def run(args,check=True):
 p=subprocess.run(args,capture_output=True,text=True,timeout=25)
 if check and p.returncode:raise RuntimeError(str(args)+': '+p.stderr)
 return dict(returncode=p.returncode,stdout=p.stdout,stderr=p.stderr)
def active():return run(['systemctl','is-active','systemd-timesyncd.service'],False)['stdout'].strip()
def enabled():return run(['systemctl','is-enabled','systemd-timesyncd.service'],False)['stdout'].strip()
def chrony():
 p=subprocess.run(['/mnt/c/Windows/System32/wsl.exe','--system','--user','root','--exec','/usr/bin/chronyc','-n','tracking'],capture_output=True,timeout=25,cwd='/mnt/c')
 text=p.stdout.decode(errors='replace')
 if p.returncode or 'PHC0' not in text or not re.search(r'Leap status\s*:\s*Normal',text):raise RuntimeError('host agent not healthy: '+text+str(p.stderr))
 return text
def event(name,**extra):
 report['events'].append(dict(name=name,rawSeconds=raw()-started if started else None,**extra));save();print(json.dumps(report['events'][-1]),flush=True)
def phase(name,seconds,wanted):
 report['phase']=name;event('phase-start',phase=name,durationRawSeconds=seconds)
 begin=raw();end=begin+seconds;next_sample=raw();minimum={'baseline':40,'paused':90,'restored':60}[name];acknowledged=False
 while raw()<end:
  done=root/(name+'.done')
  if raw()-begin>=minimum and done.exists() and done.read_text().strip()==token:
   acknowledged=True;break
  if raw()>=next_sample:
   state=active();assert state==wanted,(name,state)
   discipline=json.loads(run([str(root/'read-clock-state')])['stdout']);tracking=chrony()
   a=raw();mono=time.clock_gettime(time.CLOCK_MONOTONIC);real=time.time();b=raw()
   report['samples'].append(dict(phase=name,rawSeconds=(a+b)/2-started,rawClock=(a+b)/2,monotonicClock=mono,realtimeClock=real,clockReadHalfWidthSeconds=(b-a)/2,discipline=discipline,tracking=tracking,guestActive=state))
   save();next_sample=raw()+15
  time.sleep(min(.5,max(0,end-raw())))
 if not acknowledged:raise TimeoutError('paired probe did not acknowledge phase '+name)
 event('phase-end',phase=name)
def interrupted(*_):raise InterruptedError('clock test interrupted; restoring guest client')
for sig in [signal.SIGINT,signal.SIGTERM,signal.SIGHUP]:signal.signal(sig,interrupted)
if not lock.acquire(str(lockpath),'bounded clock-controller A/B/A '+token,lock.boot_id()):raise SystemExit('shared GPU lock held; no test started')
# Preserve normal user ownership so a genuinely stale lock remains recoverable without root.
owner=lockpath.parent.stat()
for p in [lockpath,lockpath/'owner']:os.chown(p,owner.st_uid,owner.st_gid)
try:
 started=raw();gpu=run(['/usr/lib/wsl/lib/nvidia-smi','--query-gpu=utilization.gpu,memory.used','--format=csv,noheader,nounits'])
 assert int(gpu['stdout'].split(',')[0])<=5,gpu
 initial=dict(active=active(),enabled=enabled(),clocksource=Path('/sys/devices/system/clocksource/clocksource0/current_clocksource').read_text().strip())
 assert initial['active']=='active';report['initial']=initial;report['gpuBefore']=gpu;report['hostAgentBefore']=chrony()
 report['phase']='armed';event('armed')
 deadline=raw()+60
 while not (root/'start.ack').exists():
  if raw()>deadline:raise TimeoutError('no external owner-visibility acknowledgement')
  time.sleep(.2)
 assert (root/'start.ack').read_text().strip()==token
 phase('baseline',90,'active')
 watchdog=True
 report['watchdogCreate']=run(['systemd-run','--unit='+unit,'--on-active=300s','--timer-property=AccuracySec=1s','--property=Type=oneshot','/usr/bin/systemctl','start','systemd-timesyncd.service'])
 assert run(['systemctl','is-active',unit+'.timer'])['stdout'].strip()=='active'
 need_restore=True;run(['systemctl','stop','systemd-timesyncd.service']);event('guest-client-paused')
 phase('paused',240,'inactive')
 run(['systemctl','start','systemd-timesyncd.service']);event('guest-client-restored')
 phase('restored',120,'active')
 report['status']='complete'
except BaseException as error:
 report.update(status='failed',error=repr(error));raise
finally:
 try:
  if need_restore:
   report['restoreCommand']=run(['systemctl','start','systemd-timesyncd.service'])
   assert active()==initial['active'],'guest service restoration failed'
  if watchdog:
   report['watchdogStop']=run(['systemctl','stop',unit+'.timer',unit+'.service'],False)
   report['watchdogTimerAfter']=run(['systemctl','show',unit+'.timer','-p','ActiveState','-p','LoadState'],False)
   assert 'ActiveState=active' not in report['watchdogTimerAfter']['stdout'],'restore timer remains active'
  report['final']=dict(active=active(),enabled=enabled(),clocksource=Path('/sys/devices/system/clocksource/clocksource0/current_clocksource').read_text().strip())
  if initial:assert report['final']==initial,'original active/enabled/clocksource state differs'
  report['configurationRestored']=True
 finally:
  report['lockReleased']=lock.release(str(lockpath));report['rawTotalSeconds']=raw()-started if started else None
  if report['status']=='complete':report['phase']='complete'
  save();print(json.dumps(dict(status=report['status'],configurationRestored=report.get('configurationRestored',False),lockReleased=report['lockReleased'])),flush=True)
