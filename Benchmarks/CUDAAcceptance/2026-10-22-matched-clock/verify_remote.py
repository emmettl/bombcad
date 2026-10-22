"""Freshly rehash retained PC fields and worker inputs after all six terminal solves."""
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-matched-clock')
REMOTE = r'''
import hashlib,json,subprocess,sys
from pathlib import Path
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
config=json.loads(sys.argv[1])
for p,h in config['runtime'].items():assert sha(Path(p))==h,p
rows=[]
for relative in config['roots']:
 root=Path.home()/relative/'pack';manifest=json.loads((root/'manifest.json').read_text());receipt=json.loads((root/'receipt.json').read_text())
 assert receipt['allWorkersTerminal'] and len(receipt['rows'])==3
 assert sha(root/'remote_controller.py')==manifest['controllerSHA256']
 for n,h in manifest['workerSHA256'].items():assert sha(root/'worker'/n)==h,n
 cases=[]
 for row,case in zip(receipt['rows'],manifest['cases']):
  assert row['id']==case['id'] and row['returncode']==0
  history=root/case['history'];assert sha(history)==case['historySHA256']
  inp=Path(case['physicalInput']);assert sha(inp/'job.json')==case['jobSHA256']
  job=json.loads((inp/'job.json').read_text())
  for n,h in job['files'].items():assert sha(inp/n)==h,n
  output=Path(row['output']);files={}
  for n,pin in row['numericFiles'].items():
   p=output/n;actual=dict(sha256=sha(p),bytes=p.stat().st_size);assert actual==pin,n;files[n]=actual
  cases.append(dict(id=row['id'],output=str(output),numericFiles=files))
 rows.append(dict(remoteRoot=str(root),mode=manifest['mode'],cases=cases,workerSHA256=manifest['workerSHA256']))
print(json.dumps(dict(verified=True,stages=rows,python=sys.version,selectedRuntimePins=config['runtime'],
 gpu=subprocess.check_output(['nvidia-smi','--query-gpu=name,uuid,driver_version','--format=csv,noheader'],text=True).strip()),indent=2))
'''


def main():
    roots = [json.loads((ROOT / (mode + '-controller.json')).read_text())['remote']
             for mode in ['baseline', 'forced']]
    parent = ROOT.parent / '2026-10-22-native-pressure-cross-replay/cuda-own/receipt.json'
    archive = Path(__file__).resolve().parent.parent / '2026-10-22-native-pressure-cross-replay/archive.json'
    import hashlib
    assert hashlib.sha256(parent.read_bytes()).hexdigest() == json.loads(archive.read_text())['manifest']['cuda-own/receipt.json']['sha256']
    runtime = json.loads(parent.read_text())['selectedRuntimePins']
    command = 'bombcad-ml/venv/bin/python -B -c ' + shlex.quote(REMOTE) + ' ' + shlex.quote(json.dumps(dict(roots=roots,runtime=runtime)))
    result = subprocess.check_output(['ssh', '-o', 'BatchMode=yes', 'bombcad-pc', command], text=True)
    data = json.loads(result)
    assert data['verified']
    (ROOT / 'remote-verification.json').write_text(result)
    print(json.dumps(dict(verified=True,stages=len(data['stages']),cases=sum(len(s['cases']) for s in data['stages']))))


if __name__ == '__main__':
    main()
