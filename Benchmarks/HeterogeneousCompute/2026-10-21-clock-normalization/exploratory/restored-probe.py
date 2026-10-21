import json,subprocess,sys,time
from pathlib import Path
out=Path('/private/tmp/bombcad-clock-pause')
code='import json,pathlib;print(json.dumps(json.loads(pathlib.Path("bombcad-clock-pause-01a15d45/experiment.json").read_text())["phase"]))'
def phase():return json.loads(subprocess.check_output(['ssh','bombcad-pc',"python3 -c '"+code+"'"],text=True,timeout=15))
end=time.monotonic()+120
while True:
 p=phase()
 if p=='restored':break
 if p in ('complete','failed') or time.monotonic()>end:raise RuntimeError('restored window missed: '+p)
 time.sleep(1)
(out/'paired-restored-before.json').write_text(json.dumps(dict(phase=p)))
with (out/'paired-restored.log').open('w') as log:
 subprocess.run([sys.executable,'Scripts/cuda/clock-probe.py','bombcad-pc','--out',str(out/'paired-restored.json'),'--context','A/B/A restored phase: guest timesyncd active again, host PHC chronyd healthy; shared compute lock held','--durations','0,5','--repetitions','3'],stdout=log,stderr=subprocess.STDOUT,check=True)
p=phase();(out/'paired-restored-after.json').write_text(json.dumps(dict(phase=p)));assert p=='restored',p
print('restored paired probe completed within phase')
