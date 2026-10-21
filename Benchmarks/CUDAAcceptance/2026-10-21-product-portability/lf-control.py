"""Nominal LF CSV control against the saved CRLF judgement, no physics rerun."""
import json,subprocess
from pathlib import Path
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-product-portability-v4');r=json.loads((root/'study.json').read_text());reference=json.loads((root/'judged.json').read_text())
source=(root/'peaks.csv').read_bytes();assert b'\r\n' in source
(root/'peaks-lf.csv').write_bytes(source.replace(b'\r\n',b'\n'))
cmd=r['command'][:]
for flag,value in [('--peaks',str(root/'peaks-lf.csv')),('--variants','repeat:repeat'),('--factors','1'),('--scales','0'),('--draws','1'),('--out',str(root/'judged-lf.json'))]:cmd[cmd.index(flag)+1]=value
(root/'lf-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (root/'judge-lf.log').open('w') as f:
 p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
 (root/'lf-process.json').write_text(json.dumps(dict(pid=p.pid,pgid=p.pid))+'\n');code=p.wait()
assert code==0,code
other=json.loads((root/'judged-lf.json').read_text());assert len(reference['buildings'])==len(other['buildings'])
i=reference['grid'].index([1,0]);assert other['grid']==[[1,0]]
for a,b in zip(reference['buildings'],other['buildings']):
 for key in ['object','distanceM','walls','wall','roof']:assert a.get(key)==b.get(key),(a['object'],key)
 for metric in ['wallsModerate','wallsHeavy','roofModerate']:
  if 'repeat:repeat' in a[metric]:assert a[metric]['repeat:repeat'][i]==b[metric]['repeat:repeat'][0]
(root/'lf-control.json').write_text(json.dumps(dict(status='complete',buildings=len(other['buildings']),pair=[1,0],allNominalOutcomesIdentical=True,scope='Standard CRLF versus LF CSV at the same full-precision loads; one deterministic draw, no scatter.'),indent=2)+'\n')
print('LF/CRLF nominal outcomes identical for',len(other['buildings']),'buildings')
