"""Freshly verify retained full fields, auxiliary streams, workers and physical jobs."""
import json
from pathlib import Path
import shlex
import subprocess

from run_metal import ROOT, load

SCRIPT = r'''
import hashlib,json,subprocess,sys
from pathlib import Path
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
rows=[]
for relative in json.loads(sys.argv[1]):
 root=Path.home()/relative/'pack';config=json.loads((root/'manifest.json').read_text());receipt=json.loads((root/'receipt.json').read_text())
 assert receipt['allWorkersTerminal'] and receipt['allOriginalNumericParity'] and len(receipt['rows'])==3
 assert sha(root/'remote_controller.py')==config['controllerSHA256']
 for n,h in config['workerSHA256'].items():assert sha(root/'worker'/n)==h,n
 for p,h in config['runtimePins'].items():assert sha(Path(p))==h,p
 cases=[]
 for case,row in zip(config['cases'],receipt['rows']):
  assert row['id']==case['id'] and row['returncode']==0 and row['allOriginalNumericBytesEqual']
  physical=Path(row['physicalInput']);assert sha(physical/'job.json')==case['jobSHA256']
  job=json.loads((physical/'job.json').read_text())
  for n,h in job['files'].items():assert sha(physical/n)==h,n
  output=Path(row['output']);actual={}
  for n,pin in row['numericFiles'].items():
   p=output/n;value=dict(sha256=sha(p),bytes=p.stat().st_size);assert value==pin,n;actual[n]=value
  original={n:v for n,v in actual.items() if n!='clock-inputs.bin'};assert original==case['originalNumeric']
  auxiliary={}
  for n,pin in row['retainedAuxiliary'].items():
   p=output.parent/n;value=dict(sha256=sha(p),bytes=p.stat().st_size);assert value==pin,n;auxiliary[n]=value
  if config['mode']=='capture':assert sha(output/'clock-inputs.bin')==sha(output.parent/'out-clock-inputs.partial.bin')
  cases.append(dict(id=row['id'],output=str(output),numericFiles=actual,auxiliary=auxiliary))
 rows.append(dict(mode=config['mode'],root=str(root),cases=cases,workerSHA256=config['workerSHA256'],runtimePins=config['runtimePins']))
print(json.dumps(dict(status='verified',stages=rows,driver=subprocess.check_output(['nvidia-smi','--query-gpu=name,uuid,driver_version','--format=csv,noheader'],text=True).strip()),indent=2))
'''


def main():
    roots=[]
    for mode in ['baseline','capture']:
        state=load(ROOT/(mode+'-controller.json'))
        assert state['status']=='terminal' and state['returncode']==0
        roots.append(state['remote'])
    command='bombcad-ml/venv/bin/python -B -c '+shlex.quote(SCRIPT)+' '+shlex.quote(json.dumps(roots))
    data=json.loads(subprocess.check_output(['ssh','-o','BatchMode=yes','bombcad-pc',command],text=True))
    assert data['status']=='verified'
    (ROOT/'remote-verification.json').write_text(json.dumps(data,indent=2)+'\n')
    print('Fresh remote full-field/auxiliary/input/worker/runtime verification passed for all six solves')


if __name__=='__main__':main()
