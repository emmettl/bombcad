"""Automatic paired-clock phase handshakes; root test restores service before releasing lock."""
import json,shlex,subprocess,sys,time
from pathlib import Path
out=Path('/private/tmp/bombcad-clock-confirm');remote='bombcad-clock-confirm-01a15d45'
def ssh(code):return subprocess.check_output(['ssh','bombcad-pc','python3 -c '+shlex.quote(code)],text=True,timeout=20)
def state():
 return json.loads(ssh(f'''import json,pathlib
r=json.loads(pathlib.Path({remote!r},'experiment.json').read_text())
e=[x for x in r['events'] if x['name']=='phase-start']
print(json.dumps(dict(status=r['status'],phase=r.get('phase'),pid=r['pid'],boot=r['boot'],token=r['token'],phaseStart=e[-1]['rawSeconds'] if e else None,lastSample=r['samples'][-1]['rawSeconds'] if r['samples'] else None)))'''))
def ack(file,r):
 ssh(f'''import pathlib;pathlib.Path({remote!r},{file!r}).write_text({r['token']!r})''')
log=(out/'experiment.log').open('w')
p=subprocess.Popen(['ssh','bombcad-pc','/mnt/c/Windows/System32/wsl.exe --distribution Ubuntu-24.04 --user root --exec /usr/bin/python3 -u /home/lemme/'+remote+'/experiment.py'],stdout=log,stderr=subprocess.STDOUT)
record={'status':'running','phases':[]}
def save():(out/'controller.json').write_text(json.dumps(record,indent=2)+'\n')
save()
try:
 end=time.monotonic()+50
 while True:
  if p.poll() is not None:raise RuntimeError('root process ended before arming')
  try:r=state()
  except subprocess.CalledProcessError:
   if time.monotonic()>end:raise
   time.sleep(.5);continue
  if r['phase']=='armed':break
  if time.monotonic()>end:raise TimeoutError('arming')
 ssh(f'''import importlib.util,json,pathlib,subprocess
root=pathlib.Path({remote!r});s=importlib.util.spec_from_file_location('lock',root/'remote-train.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
o=m.lock_owner('bombcad-ml/lock',m.boot_id());assert o and o['pid']=={r['pid']!r} and {r['token']!r} in o['what']
cmd=subprocess.check_output(['ps','-ww','-p',str({r['pid']!r}),'-o','command='],text=True);assert {remote!r}+'/experiment.py' in cmd''')
 ack('start.ack',r)
 for phase in ['baseline','paused','restored']:
  deadline=time.monotonic()+300
  while True:
   r=state()
   if r['status']=='failed' or p.poll() is not None:raise RuntimeError('root test ended: '+str(r))
   ready=r['phase']==phase and (phase!='paused' or (r['lastSample'] is not None and r['lastSample']-r['phaseStart']>=100))
   if ready:break
   if time.monotonic()>deadline:raise TimeoutError('phase '+phase)
   time.sleep(1)
  before=r
  with (out/('paired-'+phase+'.log')).open('w') as probe_log:
   subprocess.run([sys.executable,'Scripts/cuda/clock-probe.py','bombcad-pc','--out',str(out/('paired-'+phase+'.json')),'--context','Controller-acknowledged A/B/A '+phase+' under shared compute lock; no direct clock writes','--durations','0,5','--repetitions','3'],stdout=probe_log,stderr=subprocess.STDOUT,check=True,timeout=120)
  after=state();assert after['phase']==phase and after['token']==before['token'],(before,after)
  record['phases'].append(dict(phase=phase,before=before,after=after));save();ack(phase+'.done',after)
  print('paired phase verified',phase,flush=True)
 assert p.wait(timeout=150)==0
 record['status']='complete';save()
except BaseException as error:
 record.update(status='failed',error=repr(error));save();raise
finally:
 if p.poll() is None:
  # The remote process remains bounded and owns its independent restore timer.
  print('Root process still live; observe same handle and remote state; do not restart.',flush=True)
 log.close()
