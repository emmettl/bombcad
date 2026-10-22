"""Independent retained-byte, physical-input, controller and runtime verification."""
import json
from pathlib import Path
import shlex
import subprocess

from prepare import ROOT, save, load, sha


def main():
    prepared = load(ROOT / 'preparation.json')
    results = load(ROOT / 'results.json')
    for mapping in [prepared['pins'], prepared['consumed'], results['consumed']]:
        for p, h in mapping.items():
            assert sha(p) == h, p
    remote = {}
    for stage in ['own', 'cross']:
        folder = ROOT / ('cuda-' + stage)
        controller = load(ROOT / ('cuda-' + stage + '-remote.json'))
        runtime = load(folder / 'receipt.json')['selectedRuntimePins']
        wanted = {str(p.relative_to(folder)): dict(sha256=sha(p), bytes=p.stat().st_size)
                  for p in folder.rglob('*') if p.is_file()}
        config = dict(remote=controller['remote'], stage=stage, wanted=wanted, runtime=runtime)
        script = r'''import hashlib,json,pathlib
c=CONFIG
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
base=pathlib.Path.home()/c['remote'];root=base/'remote-input';out=root/('out-'+c['stage'])
actual={str(p.relative_to(out)):dict(sha256=sha(p),bytes=p.stat().st_size) for p in out.rglob('*') if p.is_file()}
assert actual==c['wanted']
for p,h in c['runtime'].items():assert sha(pathlib.Path(p))==h,p
manifest=json.loads((root/(c['stage']+'.json')).read_text())
for p,h in manifest['pins'].items():assert sha(root/p)==h,p
for row in manifest['rows']:
 for n in ['state.bin','mask.bin']:assert sha(pathlib.Path(row['remoteInput'])/n)==row['physicalFiles'][n]
controller=json.loads((base/'controller.json').read_text());assert controller['status']=='terminal' and controller['returncode']==0
print(json.dumps(dict(files=actual,controller=controller,allPhysicalInputsAndRuntimePinsVerified=True)))
'''.replace('CONFIG', repr(config))
        remote[stage] = json.loads(subprocess.check_output(['ssh', '-o', 'BatchMode=yes', 'bombcad-pc',
            'python3 -c ' + shlex.quote(script)], text=True))
    receipt = dict(status='verified', sourceSHA256=sha(__file__), remote=remote,
        localPhysicalInputsAndFrozenPinsVerified=True,
        limits='Read-only verification of these jobs and selected runtimes; no global idle or hermetic runtime claim.')
    save(ROOT / 'verification.json', receipt)
    print('All frozen/local physical inputs and both fresh remote inventories/runtime pins verified')


if __name__ == '__main__':
    main()
