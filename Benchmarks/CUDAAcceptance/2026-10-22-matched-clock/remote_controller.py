"""One three-case stage under the original shared GPU lock; no automatic solve retries."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

root = Path(sys.argv[1]).resolve()
config = json.loads((root / 'manifest.json').read_text())
mode = config['mode']
report = dict(status='waiting-lock', mode=mode, pid=os.getpid(), rows=[], commands=[])
def save():
    temporary = root / 'receipt.tmp'
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    os.replace(temporary, root / 'receipt.json')
def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''):
            h.update(block)
    return h.hexdigest()
def inventory(folder):
    return {str(p.relative_to(folder)): dict(sha256=sha(p), bytes=p.stat().st_size)
            for p in sorted(folder.rglob('*')) if p.is_file() and p.suffix in ('.bin', '.npy')}
assert sha(__file__) == config['controllerSHA256']
for name, digest in config['workerSHA256'].items():
    assert sha(root / 'worker' / name) == digest, name
for row in config['cases']:
    assert sha(root / row['history']) == row['historySHA256']
assert shutil.disk_usage(root).free > 16 * 2**30
spec = importlib.util.spec_from_file_location('shared_lock', root / 'worker/remote-train.py')
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)
boot = lock.boot_id()
report['boot'] = boot
deadline = time.monotonic() + 5400
acquired = False
child = None
identity = None
save()
def interrupted(signum, frame):
    raise KeyboardInterrupt('Controller signal ' + str(signum))
for sig in [signal.SIGHUP, signal.SIGTERM, signal.SIGINT]:
    signal.signal(sig, interrupted)
def stop_child():
    global child
    if child is None or child.poll() is not None:
        return
    assert lock.boot_id() == identity['boot']
    stat = Path(f'/proc/{child.pid}/stat')
    assert stat.read_text().split()[21] == identity['birthTicks']
    assert Path(f'/proc/{child.pid}/cmdline').read_bytes().rstrip(b'\0').split(b'\0') == [x.encode() for x in identity['command']]
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        assert lock.boot_id() == identity['boot'] and stat.read_text().split()[21] == identity['birthTicks']
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
try:
    start = time.monotonic()
    while not acquired:
        acquired = lock.acquire(str(Path.home() / 'bombcad-ml/lock'), 'matched-clock ' + mode, boot)
        if not acquired:
            if time.monotonic() - start >= 4800:
                raise RuntimeError('Lock wait expired before any solve')
            time.sleep(5)
    report['status'] = 'running'
    save()
    for case in config['cases']:
        name = case['id']
        physical = Path.home() / case['physicalInput']
        job = json.loads((physical / 'job.json').read_text())
        assert sha(physical / 'job.json') == case['jobSHA256']
        assert job['sourceSHA256'] == config['workerSHA256']['solver.cu']
        for filename, digest in job['files'].items():
            assert sha(physical / filename) == digest
        folder = root / 'cases' / name
        folder.mkdir(parents=True, exist_ok=False)
        out = folder / 'out'
        command = [sys.executable, '-B', str(root / 'worker/run.py'), str(physical),
                   '--source', str(root / 'worker/solver.cu'), '--out', str(out),
                   '--trace-columns', ','.join(map(str, case['columns'])),
                   '--cache-dir', str(Path.home() / 'bombcad-cuda/ptx-cache')]
        if mode == 'forced':
            command += ['--dt-history', str(root / case['history'])]
        with (folder / 'worker.log').open('xb') as log:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            identity = dict(pid=child.pid, boot=boot,
                birthTicks=Path(f'/proc/{child.pid}/stat').read_text().split()[21], command=command)
            report['liveProcess'] = identity
            save()
            try:
                code = child.wait(timeout=min(900, max(1, deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                stop_child()
                code = child.returncode
                identity['timedOut'] = True
        identity['returncode'] = code
        report['commands'].append(identity)
        report.pop('liveProcess')
        child = None
        row = dict(id=name, status='worker-failed' if code else 'completed', returncode=code,
                   physicalInput=str(physical), output=str(out))
        if code == 0:
            result = json.loads((out / 'result.json').read_text())
            assert result['sourceSHA256'] == config['workerSHA256']['solver.cu']
            assert result['diagnosticSourceSHA256'] == config['diagnosticSourceSHA256']
            assert result['workerFilesSHA256'] == {n: config['workerSHA256'][n] for n in ['run.py', 'job.py', 'compile.py', 'trace_columns.py']}
            actual = inventory(out)
            row.update(numericFiles=actual, result=result)
            if mode == 'baseline':
                row['allOriginalNumericBytesEqual'] = actual == case['originalNumeric']
                row['status'] = 'baseline-parity-pass' if row['allOriginalNumericBytesEqual'] else 'baseline-parity-rejected'
        report['rows'].append(row)
        save()
    for name, digest in config['workerSHA256'].items():
        assert sha(root / 'worker' / name) == digest
    report.update(status='complete-all-outcomes', allWorkersTerminal=True,
                  allBaselineNumericParity=(len(report['rows']) == 3 and all(r.get('allOriginalNumericBytesEqual') for r in report['rows'])) if mode == 'baseline' else None)
    save()
except BaseException as error:
    stop_child()
    report.update(status='failed', error=repr(error))
    report.pop('liveProcess', None)
    save()
    raise
finally:
    if acquired:
        assert lock.release(str(Path.home() / 'bombcad-ml/lock'))
