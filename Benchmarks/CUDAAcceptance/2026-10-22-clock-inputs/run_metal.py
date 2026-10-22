"""One declared clock capture per corrected Metal pilot; refuse any parity failure."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-clock-inputs')
BASE = ROOT.parent / '2026-10-22-fixed-terrain-reference'
OLD = ROOT.parent / '2026-10-22-metal-pressure-inputs'
COLUMNS = {'made-perimeter-s1-1': [62902], 'made-perimeter-s3-1': [134058, 250097], 'beirut-p0-1': [187747]}


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for b in iter(lambda: stream.read(1048576), b''):
            h.update(b)
    return h.hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def files(root):
    for folder, dirs, names in os.walk(root):
        dirs[:] = [n for n in dirs if not any(s in n.casefold() for s in ['blind', 'vasudev', '__pycache__'])]
        for name in names:
            if not any(s in name.casefold() for s in ['blind', 'vasudev']):
                yield Path(folder) / name


def main():
    assert not (ROOT / 'metal-capture.json').exists(), 'Observe existing capture, never duplicate it'
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPO, text=True), 'Publish before capture'
    sys.path.insert(0, str(REPO / 'Scripts/cuda'))
    spec = importlib.util.spec_from_file_location('queue_helpers', REPO / 'Scripts/cuda/field-queue.py')
    q = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(q)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    archive = load(HERE.parent / OLD.name / 'archive.json')['manifest']
    frozen = load(BASE / 'run.json')
    runtime = ROOT / 'runtime-metal'
    sources = ROOT / 'sources-metal'
    runtime.mkdir(exist_ok=False)
    sources.mkdir(exist_ok=False)
    exe = (REPO / '.build/release/scenebench').resolve()
    build = load(ROOT / 'validation/release-build.json')
    assert build['returncode'] == 0 and sha(exe) == build['binarySHA256']
    for path, h in build['sourceSHA256'].items():
        assert sha(path) == h, path
    shutil.copyfile(exe, runtime / 'scenebench')
    (runtime / 'scenebench').chmod(0o755)
    for bundle in exe.parent.glob('*.bundle'):
        if 'test' not in bundle.name.casefold():
            shutil.copytree(bundle, runtime / bundle.name)
    pins = {str(BASE / n): p['sha256'] for n, p in frozen['frozenFiles'].items() if n.startswith('inputs/')}
    consumed = {}

    def old_pin(path):
        assert sha(path) == archive[str(path.relative_to(OLD))]['sha256'], path
        consumed[str(path)] = sha(path)
        return path

    def linked_version(path):
        text = subprocess.check_output(['otool', '-l', str(path)], text=True)
        match = re.search(r'\bminos\s+(\S+)\s+sdk\s+(\S+)', text)
        assert match
        return dict(minOS=match[1], sdk=match[2])

    versions = dict(original=linked_version(old_pin(OLD/'runtime/scenebench')), current=linked_version(exe))
    assert versions['original'] == versions['current'], 'Preserve the original linked SDK for nil Metal options'

    resource = {str(p.relative_to(runtime)): sha(p) for p in files(runtime) if p.suffix == '.metal'}
    expected = {str(p.relative_to(OLD / 'runtime')): sha(old_pin(p))
                for p in files(OLD / 'runtime') if p.suffix == '.metal'}
    assert resource == expected, 'Producer shader resources must remain byte-identical'
    snapshots = []
    chosen = list(files(REPO / 'Sources')) + [REPO / 'Package.swift', REPO / 'Package.resolved',
        REPO / 'Scripts/cuda/field-queue.py', Path(__file__), HERE / 'plan.md', Path(os.sys.executable).resolve()]
    chosen += [p for p in (REPO/'Scripts/cuda').glob('*.py') if p not in chosen]
    for i, path in enumerate(chosen):
        dest = sources / f'{i:04d}-{path.name}'
        shutil.copyfile(path, dest)
        pins[str(path)] = pins[str(dest)] = sha(dest)
        snapshots.append(dict(original=str(path), snapshot=str(dest), sha256=sha(dest)))
    pins.update({str(p): sha(p) for p in files(runtime)})
    report = dict(status='running', revision=revision, controllerPID=os.getpid(), boot=q.boot_id(),
        pins=pins, consumed=consumed, snapshots=snapshots, producerResourcesSHA256=resource,
        linkedBuildVersions=versions, commands=[], rows=[])
    deadline = time.monotonic() + 5400

    def save():
        q.atomic(ROOT / 'metal-capture.json', report)

    def verify():
        for mapping in [pins, consumed]:
            for path, h in mapping.items():
                assert sha(path) == h, path

    env = q.clean_env(dict(slotEnvironment={}, revisionObservedAtInit=revision, worktreeDirtyAtInit=False))
    for key in ['PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL']:
        env.pop(key, None)
    save()
    try:
        for job in frozen['jobs']:
            name = job['id']
            original = OLD / 'cases' / name / 'inputs'
            for path in original.iterdir():
                if path.suffix == '.npy' or path.name in ['pressure-trace.json', 'pressure-inputs.json', 'diagnostic-state-hashes.json']:
                    old_pin(path)
            expected_numeric = {p.name: sha(p) for p in original.glob('*.npy')}
            args = []
            it = iter(job['arguments'])
            for key in it:
                if key in ['--out', '--initial-state-diagnostic', '--cuda-source']:
                    next(it)
                else:
                    args.append(key)
            output = ROOT / 'metal' / name
            output.parent.mkdir(exist_ok=True)
            command = [str(Path.home() / '.local/bin/gpu-slot'), '--mem', str(job['run']['estimate']['memGB']),
                str(runtime / 'scenebench'), *args, '--trace-columns', ','.join(map(str, COLUMNS[name])),
                '--trace-pressure', '--trace-pressure-inputs', '--trace-clock-inputs',
                '--diagnostic-state-hashes', '--out', str(output)]
            verify()
            with (ROOT / (name + '-metal.log')).open('xb') as log:
                proc = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                identity = q.process_snapshot(proc.pid)
                entry = dict(pid=proc.pid, boot=q.boot_id(), identity=identity, command=command)
                report['liveProcess'] = entry
                save()
                def same():
                    actual = q.process_snapshot(proc.pid)
                    return (q.boot_id() == entry['boot'] and actual is not None and identity is not None
                            and actual['birth'] == identity['birth'] and actual['command'] == identity['command'])
                try:
                    code = proc.wait(timeout=max(1, deadline-time.monotonic()))
                except subprocess.TimeoutExpired:
                    assert same()
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        code = proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        assert same()
                        os.killpg(proc.pid, signal.SIGKILL)
                        code = proc.wait()
                    entry['timedOut'] = True
                entry['returncode'] = code
            assert not q.group_alive(proc.pid), 'An owned descendant remains live'
            report['commands'].append(entry)
            report.pop('liveProcess')
            row = dict(id=name, returncode=code, status='worker-failed')
            report['rows'].append(row)
            save()
            assert code == 0, row
            numeric = {p.name: sha(p) for p in output.glob('*.npy')}
            row.update(numericFilesSHA256=numeric, allOriginalNumericBytesEqual=numeric == expected_numeric)
            row['metadataParity'] = {n: (output/n).read_bytes() == (original/n).read_bytes()
                for n in ['pressure-trace.json', 'pressure-inputs.json', 'diagnostic-state-hashes.json']}
            info = load(output / 'clock-inputs.json')
            row.update(clockRecordBytes=(output/'clock-inputs.bin').stat().st_size,
                clockSamples=info['samples'], clockSHA256=sha(output/'clock-inputs.bin'))
            passed = row['allOriginalNumericBytesEqual'] and all(row['metadataParity'].values())
            row.update(status='capture-parity-pass' if passed else 'capture-parity-rejected')
            save()
            assert passed, row
            assert load(output / 'meta.json')['stable'] and info['complete']
            assert row['clockRecordBytes'] == info['samples'] * info['recordWords'] * 4
            verify()
        report.update(status='complete-all-outcomes', allThreeCaptureGatesPass=True, allOwnedGroupsTerminal=True)
        save()
    except BaseException as error:
        report.update(status='failed', error=repr(error))
        save()
        raise
    print(json.dumps(dict(status=report['status'], rows=report['rows']), indent=2))


if __name__ == '__main__':
    main()
