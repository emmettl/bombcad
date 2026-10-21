"""Keep the compute reservation until independent paired checks accept the single-owner policy."""
import hashlib,json,shlex,subprocess,sys,time
from pathlib import Path
out=Path('/private/tmp/bombcad-clock-normalize');remote='bombcad-clock-normalize-01a15d45'
def ssh(code):return subprocess.check_output(['ssh','bombcad-pc','python3 -c '+shlex.quote(code)],text=True,timeout=20)
def state():return json.loads(ssh(f'''import json,pathlib
r=json.loads(pathlib.Path({remote!r},'experiment.json').read_text())
print(json.dumps(dict(status=r['status'],phase=r.get('phase'),pid=r['pid'],boot=r['boot'],token=r['token'],validationStart=r.get('validationStartRawSeconds'),lastSample=r['samples'][-1]['rawSeconds'] if r['samples'] else None)))'''))
def write(name,value):ssh(f'import pathlib;pathlib.Path({remote!r},{name!r}).write_text({value!r})')
record={'status':'running'}
def save():(out/'controller.json').write_text(json.dumps(record,indent=2)+'\n')
log=(out/'experiment.log').open('w');p=subprocess.Popen(['ssh','bombcad-pc','/mnt/c/Windows/System32/wsl.exe --distribution Ubuntu-24.04 --user root --exec /usr/bin/python3 -u /home/lemme/'+remote+'/experiment.py'],stdout=log,stderr=subprocess.STDOUT);save()
try:
 end=time.monotonic()+50
 while True:
  if p.poll() is not None:raise RuntimeError('root normalizer ended before arming')
  try:r=state()
  except subprocess.CalledProcessError:
   if time.monotonic()>end:raise
   time.sleep(.5);continue
  if r['phase']=='armed':break
  if time.monotonic()>end:raise TimeoutError('arming')
 ssh(f'''import importlib.util,pathlib,subprocess
root=pathlib.Path({remote!r});s=importlib.util.spec_from_file_location('lock',root/'remote-train.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
o=m.lock_owner('bombcad-ml/lock',m.boot_id());assert o and o['pid']=={r['pid']!r} and {r['token']!r} in o['what']
assert {remote!r}+'/experiment.py' in subprocess.check_output(['ps','-ww','-p',str({r['pid']!r}),'-o','command='],text=True)''')
 write('start.ack',r['token'])
 end=time.monotonic()+200
 while True:
  r=state()
  if r['status']=='failed' or p.poll() is not None:raise RuntimeError('normalizer ended: '+str(r))
  if r['phase']=='validation' and r['lastSample'] is not None and r['lastSample']-r['validationStart']>=120:break
  if time.monotonic()>end:raise TimeoutError('settling')
  time.sleep(2)
 stats=[]
 for name,script,durations,reps in [('paired-normalized','Scripts/cuda/clock-probe.py','0,1,5,15','3'),('paired-long',str(out/'long-probe.py'),'0,60','1')]:
  before=state();assert before['phase']=='validation'
  with (out/(name+'.log')).open('w') as probe_log:subprocess.run([sys.executable,script,'bombcad-pc','--out',str(out/(name+'.json')),'--context','Single host-time owner validation; guest client paused under restore guard and shared compute lock','--durations',durations,'--repetitions',reps],stdout=probe_log,stderr=subprocess.STDOUT,check=True,timeout=240)
  after=state();assert after['phase']=='validation' and after['token']==before['token']
  data=json.loads((out/(name+'.json')).read_text());assert data['status']=='complete'
  rows=[x for x in data['rows'] if x['requestedSeconds']>=5]
  ppm=[abs(x['wslSeconds']['CLOCK_MONOTONIC']/x['wslSeconds']['CLOCK_MONOTONIC_RAW']-1)*1e6 for x in rows]
  raw_native=[abs(x['wslSeconds']['CLOCK_MONOTONIC_RAW']-x['windows']['qpcSeconds']) for x in rows]
  utc_native=[abs(x['windows']['utcSeconds']-x['windows']['qpcSeconds']) for x in rows]
  assert max(ppm)<=500,(name,ppm)
  assert max(raw_native)<=.02,(name,raw_native)
  assert max(utc_native)<=.05,(name,utc_native)
  stats.append(dict(probe=name,maxAbsoluteAdjustedRawPPM=max(ppm),maxRawNativeBracketingSeconds=max(raw_native),maxNativeUTCQPCDifferenceSeconds=max(utc_native),fileSHA256=hashlib.sha256((out/(name+'.json')).read_bytes()).hexdigest(),before=before,after=after));record['validation']=stats;save();print('independent paired check passed',name,flush=True)
 r=state();assert r['phase']=='validation';write('commit.json',json.dumps(dict(token=r['token'],accepted=True,criteria=dict(maxAdjustedRawPPM=500,maxRawNativeBracketingSeconds=.02,maxNativeUTCQPCDifferenceSeconds=.05),validation=stats)))
 assert p.wait(timeout=60)==0
 record['status']='complete';save()
except BaseException as error:
 record.update(status='failed',error=repr(error));save();raise
finally:
 if p.poll() is None:print('Root normalizer is still live and bounded; observe its same handle and independent rollback guard.',flush=True)
 log.close()
