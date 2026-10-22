"""Single-run scalar compensation gate; never replace an existing experiment root."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(__file__).resolve().parent
root = Path(os.environ.get('BOMBCAD_DATA', '/Volumes/StudioData/bombcad')) / 'experiments/2026-10-22-compensated-scalar'
root.mkdir(parents=True, exist_ok=False)
frozen = root / 'sources'
frozen.mkdir()
digest = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
pins = {}
for name in ['plan.md', 'reference.py', 'probe.swift', 'run.py']:
    shutil.copyfile(source / name, frozen / name)
    pins[name] = digest(frozen / name)
report = dict(status='preparing', sourceSHA256=pins, controllerPID=os.getpid(), commands=[])


def save():
    (root / 'run.json').write_text(json.dumps(report, indent=2)+'\n')


def execute(command, label, timeout):
    entry = dict(label=label, command=command)
    report['commands'].append(entry)
    with (root / (label+'.log')).open('wb') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        entry.update(pid=process.pid, pgid=process.pid)
        report['status'] = 'running'
        save()
        # An observation timeout is not grounds to relaunch; keep the exact identity and outputs.
        entry['returncode'] = process.wait(timeout=timeout)
        entry['terminal'] = True
        save()
        if entry['returncode'] != 0:
            raise RuntimeError(f'{label} exited {entry["returncode"]}')


save()
try:
    execute([sys.executable, str(frozen/'reference.py'), 'fixtures', str(root/'fixtures.json')], 'fixtures', 60)
    report['fixtureSHA256'] = digest(root/'fixtures.json')
    report['swiftVersion'] = subprocess.check_output(['swiftc','--version'],text=True)
    execute(['swiftc','-O','-warnings-as-errors','-target','arm64-apple-macos15.0',str(frozen/'probe.swift'),'-o',str(root/'probe')], 'compile', 300)
    report['executableSHA256'] = digest(root/'probe')
    save()
    execute([str(Path.home()/'.local/bin/gpu-slot'),'--mem','1',str(root/'probe'),str(root/'fixtures.json'),str(root/'gpu.json')], 'gpu', 600)
    execute([sys.executable,str(frozen/'reference.py'),'audit',str(root/'fixtures.json'),str(root/'gpu.json'),str(root/'results.json')], 'audit', 300)
    assert all(digest(source/name)==sha and digest(frozen/name)==sha for name,sha in pins.items())
    assert digest(root/'fixtures.json') == report['fixtureSHA256']
    assert digest(root/'probe') == report['executableSHA256']
    report['status'] = 'complete'
except BaseException as error:
    report.update(status='failed', error=repr(error))
    raise
finally:
    report['retainedFiles'] = {str(p.relative_to(root)):dict(sha256=digest(p),bytes=p.stat().st_size) for p in sorted(root.rglob('*')) if p.is_file() and p.name!='run.json'}
    save()
print(json.dumps({k:v for k,v in report.items() if k not in ['retainedFiles','sourceSHA256']},indent=2))
