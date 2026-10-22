"""One-attempt independent Metal input capture; no interpretation before all gates pass."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
BASE = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')
ROOT = BASE.parent / '2026-10-22-metal-pressure-inputs'
COLUMNS = {'made-perimeter-s1-1': [62902], 'made-perimeter-s3-1': [134058, 250097], 'beirut-p0-1': [187747]}


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def files(root):
    for folder, dirs, names in os.walk(root):
        dirs[:] = [n for n in dirs if n != '__pycache__' and not any(x in n.lower() for x in ['blind', 'vasudev'])]
        for name in sorted(names):
            if not any(x in name.lower() for x in ['blind', 'vasudev']):
                yield Path(folder) / name


def main():
    sys.path.insert(0, str(BASE / 'analysis/cuda'))
    q = module('capture_queue', REPO / 'Scripts/cuda/field-queue.py')
    phase = module('capture_phase', BASE / 'analysis/cuda/diagnose-phase.py')
    frozen = q.read(BASE / 'run.json')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=REPO, text=True), 'Publish before capture'
    ROOT.mkdir(exist_ok=False)
    for name in ['runtime', 'sources', 'analysis', 'cases']:
        (ROOT / name).mkdir()
    exe = (REPO / '.build/release/scenebench').resolve()
    shutil.copyfile(exe, ROOT / 'runtime/scenebench')
    (ROOT / 'runtime/scenebench').chmod(0o755)
    for bundle in exe.parent.glob('*.bundle'):
        if 'test' not in bundle.name.lower():
            shutil.copytree(bundle, ROOT / 'runtime' / bundle.name)
    chosen = [REPO / 'Package.swift', REPO / 'Package.resolved', Path(sys.executable).resolve(), HERE / 'plan.md', Path(__file__)]
    chosen += list(files(REPO / 'Sources'))
    chosen += [REPO / 'Scripts/cuda/field-queue.py', BASE / 'analysis/ml/remote-train.py']
    chosen += list((BASE / 'analysis/cuda').glob('*.py'))
    pins = {str(BASE / n): v['sha256'] for n, v in frozen['frozenFiles'].items() if n.startswith('inputs/')}
    numpy_core = Path(np._core._multiarray_umath.__file__).resolve()
    pins[str(numpy_core)] = q.digest(numpy_core)
    snapshots = []
    for i, path in enumerate(chosen):
        dest = ROOT / 'sources' / f'{i:04d}-{path.name}'
        shutil.copyfile(path, dest)
        pins[str(path)] = q.digest(path)
        pins[str(dest)] = q.digest(dest)
        snapshots.append(dict(original=str(path), snapshot=str(dest), sha256=q.digest(dest)))
    for path in files(ROOT / 'runtime'):
        pins[str(path)] = q.digest(path)
    report = dict(status='running', revision=revision, baselineRevision=frozen['revision'], controllerPID=os.getpid(),
                  boot=q.boot_id(), numpyVersion=np.__version__, pins=pins, snapshots=snapshots, commands=[], rows=[])

    def save():
        q.atomic(ROOT / 'run.json', report)

    def verify():
        for path, digest in pins.items():
            assert q.digest(path) == digest, 'Consumed file changed: ' + path

    env = q.clean_env(dict(slotEnvironment={}, revisionObservedAtInit=revision, worktreeDirtyAtInit=False))
    for key in ['PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL']:
        env.pop(key, None)

    def run(command, label):
        verify()
        with (ROOT / (label + '.log')).open('wb') as log:
            process = subprocess.Popen(command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            entry = dict(label=label, command=command, pid=process.pid, pgid=process.pid, identity=q.process_snapshot(process.pid))
            report['liveProcess'] = entry
            save()
            entry['returncode'] = process.wait()
        assert not q.group_alive(process.pid), 'Owned descendant remains live'
        report['commands'].append(entry)
        report.pop('liveProcess')
        save()
        verify()
        assert entry['returncode'] == 0, (label, entry['returncode'])

    save()
    try:
        for job in frozen['jobs']:
            name = job['id']
            columns = COLUMNS[name]
            baseline = BASE / 'cases' / name / 'metal'
            input_folder = BASE / 'cases' / name / 'input'
            physical = q.read(input_folder / 'job.json')
            for path in [input_folder / 'job.json', *[input_folder / n for n in physical['files']], *baseline.glob('*.npy')]:
                pins[str(path)] = q.digest(path)
            for filename, digest in physical['files'].items():
                assert q.digest(input_folder / filename) == digest
            original = {p.name: q.digest(p) for p in baseline.glob('*.npy')}
            args = []
            i = 0
            while i < len(job['arguments']):
                key = job['arguments'][i]
                i += 1
                if key in ['--out', '--initial-state-diagnostic', '--cuda-source']:
                    i += 1
                    continue
                args.append(key)
            row = dict(id=name, columns=columns, modes=[], uniforms=physical['uniforms'])
            report['rows'].append(row)
            for mode in ['plain', 'pressure', 'inputs']:
                out = ROOT / 'cases' / name / mode
                out.parent.mkdir(exist_ok=True)
                extra = [] if mode == 'plain' else ['--trace-columns', ','.join(map(str, columns)), '--trace-pressure']
                if mode == 'inputs':
                    extra += ['--trace-pressure-inputs']
                run([str(Path.home() / '.local/bin/gpu-slot'), '--mem', str(job['run']['estimate']['memGB']),
                     str(ROOT / 'runtime/scenebench'), *args, *extra, '--diagnostic-state-hashes', '--out', str(out)], name + '-' + mode)
                assert q.read(out / 'meta.json')['stable'] is True
                diagnostic = {'pressure-trace.npy', 'pressure-inputs.npy', 'pressure-input-endpoints.npy'}
                actual = {p.name: q.digest(p) for p in out.glob('*.npy') if p.name not in diagnostic}
                assert actual == original, 'Ordinary arrays differ from corrected reference: ' + name + '/' + mode
                row['modes'].append(dict(mode=mode, datasetSHA256=actual, state=q.read(out / 'diagnostic-state-hashes.json')))
                save()
            assert all(v['state'] == row['modes'][0]['state'] for v in row['modes']), 'Coarse state parity failed'
            plain_trace = ROOT / 'cases' / name / 'pressure'
            raw = ROOT / 'cases' / name / 'inputs'
            assert q.digest(plain_trace / 'pressure-trace.npy') == q.digest(raw / 'pressure-trace.npy')
            assert (plain_trace / 'pressure-trace.json').read_bytes() == (raw / 'pressure-trace.json').read_bytes()
            pressure_meta, pressure = phase.load(raw)
            replay = phase.summarize(pressure_meta, pressure)
            assert all('fused' in c['exactAccumulationPolicies'] for c in replay['columns']), 'Native seeded replay failed'
            q.atomic(raw / 'native-replay.json', replay)
            values = np.load(raw / 'pressure-inputs.npy', allow_pickle=False)
            endpoints = np.load(raw / 'pressure-input-endpoints.npy', allow_pickle=False)
            info = q.read(raw / 'pressure-inputs.json')
            assert info['columns'] == columns and info['steps'] == pressure_meta['steps'] and info['times'] == pressure_meta['times']
            assert values.shape == (len(info['times']), len(columns), 16) and values.dtype == np.dtype('<f4')
            assert endpoints.shape == (2, len(columns), 16) and endpoints.dtype == np.dtype('<f4')
            assert np.isfinite(values).all()
            assert np.array_equal(values[[0, -1]].view(np.uint32), endpoints.view(np.uint32)), 'Independent endpoint mismatch'
            initial = np.fromfile(input_folder / 'state.bin', dtype='<u4').reshape(-1, 5)
            descriptors = np.fromfile(input_folder / 'columns.bin', dtype='<f4').reshape(-1, 4)
            plane = physical['shape'][0] * physical['shape'][1]
            for selected, column in enumerate(columns):
                c = descriptors[column]
                words = values[:, selected].view(np.uint32)
                assert c[3] > 0 and np.all(words[:, :4] == c.view(np.uint32))
                weights = np.array([np.float32(1) - c[2], c[2]], dtype='<f4')
                assert np.all(words[:, 4:6] == weights.view(np.uint32))
                for side, k in enumerate(c[:2]):
                    assert np.array_equal(words[0, 6 + 5 * side:11 + 5 * side], initial[column % plane + plane * int(k)]), 'Original initial state mismatch'
            row.update(captureGatesPass=True, nativeReplay=replay, samples=len(info['times']))
            save()
        verify()
        report.update(status='complete-all-outcomes', allThreeCaptureGatesPass=True, allConsumedPinsUnchanged=True, allOwnedGroupsTerminal=True)
        save()
        print(json.dumps({k: v for k, v in report.items() if k not in ['pins', 'snapshots', 'rows']}, indent=2))
    except BaseException as error:
        report.update(status='failed', error=repr(error))
        save()
        raise


if __name__ == '__main__':
    main()
