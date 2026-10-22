"""Deploy one frozen three-case stage, observe it once and retain raw fields on the PC."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-matched-clock')
OLD = ROOT.parent / '2026-10-22-phase-pressure-inputs'
BASE = ROOT.parent / '2026-10-22-fixed-terrain-reference'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def main():
    p = argparse.ArgumentParser()
    p.add_argument('mode', choices=['baseline', 'forced'])
    mode = p.parse_args().mode
    if mode == 'forced':
        assert load(ROOT / 'baseline/receipt.json')['allBaselineNumericParity']
    preflight = load(ROOT / 'preflight.json')
    for mapping in [preflight['pins'], preflight['consumed']]:
        for name, digest in mapping.items():
            assert sha(name) == digest, name
    build = load(ROOT / 'worker-build.json')
    for name, digest in build['workerSHA256'].items():
        assert sha(ROOT / 'variant' / name) == digest
    receipt = ROOT / (mode + '-controller.json')
    assert not receipt.exists(), 'Observe the existing stage rather than restarting'
    pack = ROOT / (mode + '-pack')
    pack.mkdir(exist_ok=False)
    shutil.copytree(ROOT / 'variant', pack / 'worker')
    shutil.copyfile(HERE / 'remote_controller.py', pack / 'remote_controller.py')
    shutil.copyfile(__file__, ROOT / 'analysis' / ('run-' + mode + '.py'))
    old = load(OLD / 'run.json')
    archive = load(REPO / 'Benchmarks/CUDAAcceptance/2026-10-22-phase-pressure-inputs/archive.json')['files']
    cases = []
    source_hashes = set()
    for row in old['rows']:
        name = row['id']
        history = pack / 'histories' / (name + '.npy')
        history.parent.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / 'cases' / name / 'metal-dt.npy', history)
        proof = OLD / 'cases' / name / 'parity-and-endpoints.json'
        result = OLD / 'cases' / name / 'result.json'
        assert sha(proof) == archive[str(proof.relative_to(OLD))]['sha256']
        assert sha(result) == archive[str(result.relative_to(OLD))]['sha256']
        source_hashes.add(load(result)['diagnosticSourceSHA256'])
        cases.append(dict(id=name, physicalInput=row['baselineRemote'] + '/input',
            jobSHA256=sha(BASE / 'cases' / name / 'input/job.json'), columns=row['columns'],
            originalNumeric=load(proof)['traced'], history=str(history.relative_to(pack)), historySHA256=sha(history)))
    assert len(source_hashes) == 1
    config = dict(mode=mode, cases=cases, workerSHA256=build['workerSHA256'],
                  controllerSHA256=sha(pack / 'remote_controller.py'),
                  diagnosticSourceSHA256=source_hashes.pop())
    (pack / 'manifest.json').write_text(json.dumps(config, indent=2) + '\n')
    remote = 'bombcad-cuda/matched-clock/jobs/' + uuid.uuid4().hex
    state = dict(status='deploying', mode=mode, remote=remote, controllerPID=__import__('os').getpid(),
                  pins={str(x): sha(x) for x in pack.rglob('*') if x.is_file()})
    def save():
        receipt.write_text(json.dumps(state, indent=2) + '\n')
    save()
    subprocess.run(['ssh', '-o', 'BatchMode=yes', 'bombcad-pc',
        'python3 -c ' + shlex.quote('from pathlib import Path; (Path.home()/' + repr(remote) + ').mkdir(parents=True,exist_ok=False)')], check=True)
    subprocess.run(['scp', '-q', '-C', '-r', str(pack), 'bombcad-pc:' + remote + '/pack'], check=True)
    command = ['ssh', '-o', 'BatchMode=yes', 'bombcad-pc',
        'bombcad-ml/venv/bin/python -B ' + shlex.quote(remote + '/pack/remote_controller.py') + ' ' + shlex.quote(remote + '/pack')]
    with (ROOT / (mode + '-ssh.log')).open('xb') as log:
        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state.update(status='running', localSSHPID=proc.pid, command=command)
        save()
        code = proc.wait()
    state.update(status='terminal', returncode=code)
    save()
    dest = ROOT / mode
    dest.mkdir(exist_ok=False)
    subprocess.run(['scp', '-q', 'bombcad-pc:' + remote + '/pack/receipt.json', str(dest / 'receipt.json')], check=True)
    result = load(dest / 'receipt.json')
    for row in result['rows']:
        folder = dest / row['id']
        folder.mkdir()
        subprocess.run(['scp', '-q', 'bombcad-pc:' + remote + '/pack/cases/' + row['id'] + '/worker.log', str(folder / 'worker.log')], check=True)
        if row['returncode'] == 0:
            for name in ['targets.npy', 'firstPhaseImpulse.npy', 'mask.npy', 'dt.npy', 'trace.npy', 'trace.json',
                         'pressure-inputs.npy', 'pressure-inputs.json', 'result.json', 'clock-events.json']:
                subprocess.run(['scp', '-q', 'bombcad-pc:' + row['output'] + '/' + name, str(folder / name)], check=True)
            for name, pin in row['numericFiles'].items():
                path = folder / name
                if path.exists():
                    assert sha(path) == pin['sha256'] and path.stat().st_size == pin['bytes'], path
    for path, digest in state['pins'].items():
        assert sha(path) == digest
    print(json.dumps(dict(status=result['status'], mode=mode, allBaselineNumericParity=result.get('allBaselineNumericParity'),
                         rows=[{k: r[k] for k in ['id', 'status', 'returncode']} for r in result['rows']]), indent=2))
    raise SystemExit(code)


if __name__ == '__main__':
    main()
