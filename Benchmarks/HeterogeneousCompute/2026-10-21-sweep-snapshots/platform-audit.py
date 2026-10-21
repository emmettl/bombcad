"""Final-source Linux unit/process controls and staged test completion identity."""
import hashlib,json,re,subprocess
from pathlib import Path
tmp=Path('/private/tmp/bombcad-sweep-snapshots');ident=(tmp/'final-test-id').read_text();assert re.fullmatch('[0-9a-f]{32}',ident)
stage='bombcad-sweeps/staging/'+ident
with (tmp/'pc-unit.log').open('wb') as out:
 p=subprocess.run(['ssh','bombcad-pc','cd '+stage+'/src && python3 Scripts/test-remote-sweep.py'],stdout=out,stderr=subprocess.STDOUT)
assert p.returncode==0,p.returncode
with (tmp/'forced-stop-pc.json').open('wb') as out,(tmp/'forced-stop-pc.log').open('wb') as err:
 p=subprocess.run(['ssh','bombcad-pc','cd '+stage+'/src && python3 -'],input=(tmp/'forced-stop-pc.py').read_bytes(),stdout=out,stderr=err)
assert p.returncode==0,p.returncode
force=json.loads((tmp/'forced-stop-pc.json').read_text());assert force['status']=='complete'
for name in ['manifest.json','request.json','started.json','completion.json']:
 data=subprocess.check_output(['ssh','bombcad-pc','cat '+stage+'/'+name]);(tmp/('final-test-'+name)).write_bytes(data)
manifest=json.loads((tmp/'final-test-manifest.json').read_text());completion=json.loads((tmp/'final-test-completion.json').read_text())
source=hashlib.sha256(Path('Scripts/remote-sweep.py').read_bytes()).hexdigest()
assert manifest['tools']['remote-sweep.py']['sha256']==source==force['runnerSHA256']
assert completion['invocation']==ident and completion['exitCode']==0 and completion['phase']=='tests'
assert 'cached completion '+ident+' exit 0' in (tmp/'final-test-recovery.log').read_text()
result=dict(status='complete',invocation=ident,runnerSHA256=source,finalTestCompletionVerified=True,linuxRunnerControlsPassed=True,linuxForcedStopPassed=True,scope='Synthetic ownership tests only; no production job targeted or numerical/performance policy changed.')
(tmp/'platform-audit.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
