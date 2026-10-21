"""Sequential bounded measured phases; never restart a completed/partial phase automatically."""
from pathlib import Path
import json,subprocess,sys,os
root=Path(__file__).resolve().parent
phases=[('confirm-small',['supervise-confirm.py','confirm-small','candidate.py','blast64','cooling32','cooling64','terrain256']),('null-confirm',['supervise-confirm.py','null-confirm','baseline.py','blast64','cooling32','cooling64','terrain256']),('diagnostic',['diagnose.py'])]
assert not (root/'confirmation-campaign.json').exists(),'campaign state exists; observe its handle, do not restart'
assert all(not (root/name).exists() for name,_ in phases),'phase output exists; do not overwrite'
r=dict(status='running',pid=os.getpid(),pgid=os.getpgrp(),phases=[])
def save():(root/'confirmation-campaign.json').write_text(json.dumps(r,indent=2)+'\n')
save()
for label,args in phases:
 cmd=[sys.executable,str(root/args[0]),*args[1:]]
 with (root/(label+'-supervisor.log')).open('wb') as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT,start_new_session=True);r['liveProcess']=dict(label=label,pid=p.pid,pgid=p.pid,command=cmd);save();code=p.wait()
 r['phases'].append(dict(label=label,returncode=code));r.pop('liveProcess',None);save()
 if code==0 and label!='diagnostic':
  monitor=json.loads((root/(label+'-state.json')).read_text())
  if monitor['externalComputeGroupObserved']:r['externalObservation']=label;code=1
 if code:
  r.update(status='failed',returncode=code);save();raise SystemExit(code)
r.update(status='complete',returncode=0);save();print(json.dumps(r,indent=2))
