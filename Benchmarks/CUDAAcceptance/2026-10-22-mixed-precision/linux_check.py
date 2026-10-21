"""Run reference checks on the existing PC runtime using unique immutable source copies."""
from pathlib import Path
import base64,hashlib,json,shlex,subprocess,uuid
files={}
for name in ['planar_euler.py','test-planar-euler.py']:
 raw=(Path('Scripts/reference')/name).read_bytes();files[name]=dict(data=base64.b64encode(raw).decode(),sha256=hashlib.sha256(raw).hexdigest())
remote='''from pathlib import Path
import base64,hashlib,json,os,platform,subprocess,sys
import numpy as np
request=json.load(sys.stdin)
root=Path.home()/'bombcad-ml/experiments'/request['id']
root.mkdir(parents=True,exist_ok=False)
for name,item in request['files'].items():
 raw=base64.b64decode(item['data']);assert hashlib.sha256(raw).hexdigest()==item['sha256'];(root/name).write_bytes(raw)
r=subprocess.run([sys.executable,str(root/'test-planar-euler.py')],capture_output=True,text=True,env=dict(os.environ,OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1'))
for name,item in request['files'].items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==item['sha256']
report=dict(path=str(root),returncode=r.returncode,stdout=r.stdout,stderr=r.stderr,python=sys.version,numpy=np.__version__,platform=platform.platform(),boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),sourceSHA256={name:item['sha256'] for name,item in request['files'].items()},numpyCoreSHA256=hashlib.sha256(Path(np._core._multiarray_umath.__file__).read_bytes()).hexdigest())
(root/'result.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
sys.exit(r.returncode)
'''
request=dict(id='mixed-unit-'+str(uuid.uuid4()),files=files)
command=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10','bombcad-pc','~/bombcad-ml/venv/bin/python -c '+shlex.quote(remote)]
r=subprocess.run(command,input=json.dumps(request),capture_output=True,text=True)
Path(__file__).with_name('linux-tests.json').write_text(r.stdout)
assert r.returncode==0,(r.returncode,r.stderr)
print(r.stdout)
