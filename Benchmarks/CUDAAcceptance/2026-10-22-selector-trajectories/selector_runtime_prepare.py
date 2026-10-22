"""Freeze the published release executable, source/resource context and qualified parent pins."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-selector-trajectories')
CAP = ROOT.parent / '2026-10-22-clock-inputs'


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''): h.update(b)
    return h.hexdigest()


def load(path): return json.loads(Path(path).read_text())


def save(path, value): Path(path).write_text(json.dumps(value, indent=2) + '\n')


def files(root):
    for folder, dirs, names in os.walk(root):
        dirs[:] = [n for n in dirs if not any(s in n.casefold() for s in ['blind', 'vasudev', '__pycache__'])]
        for n in names:
            if not any(s in n.casefold() for s in ['blind', 'vasudev']): yield Path(folder) / n


def main():
    repo = Path(sys.argv[1]).resolve()
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    audit = load(ROOT / 'control-audit.json'); assert audit['allIndependentOriginalBoundsPass']
    checkpoint = load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-selector-trajectories/implementation-archive.json')
    for n, r in checkpoint['manifest'].items(): assert sha(ROOT / n) == r['sha256'], n
    assert load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-selector-trajectories/support-refinement.json')['status'].startswith('passed')
    receipt = ROOT / 'validation/release-build.json'; assert not receipt.exists()
    source = ROOT / 'sources-metal'; source.mkdir(exist_ok=False)
    chosen = [p for p in files(repo / 'Sources') if p.suffix in ['.swift', '.metal']]
    chosen += [repo / 'Package.swift', repo / 'Package.resolved', Path(__file__)]
    chosen += sorted((repo / 'Scripts/cuda').glob('*.py'))
    snapshots = []
    for i, p in enumerate(chosen):
        dest = source / (f'{i:04d}-' + p.name); shutil.copyfile(p, dest)
        snapshots.append(dict(original=str(p), snapshot=str(dest), sha256=sha(dest)))
    command = ['swift', 'build', '-c', 'release', '--product', 'scenebench']
    with (ROOT / 'validation/release-build.log').open('xb') as log:
        proc = subprocess.Popen(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        report = dict(status='running', pid=proc.pid, command=command, revision=revision, snapshots=snapshots)
        save(receipt, report)
        try: code = proc.wait(timeout=5400)
        except subprocess.TimeoutExpired:
            if proc.poll() is None: os.killpg(proc.pid, signal.SIGTERM)
            try: code = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                if proc.poll() is None: os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
            report['timedOut'] = True
    report.update(status='terminal', returncode=code); save(receipt, report)
    assert code == 0, 'Retain failed build before any physical dispatch'
    for r in snapshots: assert sha(r['original']) == r['sha256'] == sha(r['snapshot']), r['original']
    runtime = ROOT / 'runtime-metal'; runtime.mkdir(exist_ok=False)
    exe = (repo / '.build/release/scenebench').resolve()
    shutil.copyfile(exe, runtime / 'scenebench'); (runtime / 'scenebench').chmod(0o755)
    for bundle in exe.parent.glob('*.bundle'):
        assert not any(s in str(bundle).casefold() for s in ['blind', 'vasudev'])
        shutil.copytree(bundle, runtime / bundle.name)
    linked = subprocess.check_output(['otool', '-l', str(runtime / 'scenebench')], text=True)
    (ROOT / 'validation/release-linked-sdk.txt').write_text(linked)
    version = re.search(r'\bminos\s+(\S+)\s+sdk\s+(\S+)', linked); assert version is not None
    report.update(binarySHA256=sha(runtime / 'scenebench'), linkedMinOS=version[1], linkedSDK=version[2])
    save(receipt, report); assert version[1] == version[2] == '15.0'
    archive = load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-clock-inputs/archive.json')['manifest']
    consumed = {}
    def pin(p):
        assert sha(p) == archive[str(p.relative_to(CAP))]['sha256'], p
        consumed[str(p)] = sha(p); return p
    original = load(pin(CAP / 'metal-capture.json')); assert original['allThreeCaptureGatesPass']
    resources = {str(p.relative_to(runtime)): sha(p) for p in files(runtime) if p.suffix == '.metal'}
    expected = {n[len('runtime-metal/'):]: r['sha256'] for n, r in archive.items()
                if n.startswith('runtime-metal/') and n.endswith('.metal')}
    assert resources == expected
    maker = repo / 'Sources/BlastCore/StructureTypes+GPU.swift'
    names = re.findall(r'"([^"]+)"', re.search(r'let files = \[(.*?)\]', maker.read_text(), re.S).group(1))
    shader = runtime / 'BombCAD_BlastCore.bundle/Contents/Resources/Shaders'
    prefix = runtime / 'ContinuumKit_ContactSearchMetal.bundle/Contents/Resources/Shaders/ContactSearchFunctions.metal'
    producer = prefix.read_text() + '\n' + '\n'.join((shader / (n + '.metal')).read_text() for n in names)
    assert hashlib.sha256(producer.encode()).hexdigest() == '9b71ace9e68302d44903ae6d6d391932384e29efc51db3189c34a41b04fb9eed'
    helpers = ROOT / 'analysis/qhelpers'; helpers.mkdir(exist_ok=False)
    for p in (repo / 'Scripts/cuda').glob('*.py'): shutil.copyfile(p, helpers / p.name)
    physical_inputs = {p: h for p, h in original['pins'].items()
                       if '/2026-10-22-fixed-terrain-reference/inputs/' in p}
    assert physical_inputs
    for p, h in physical_inputs.items(): assert sha(p) == h
    for row in original['rows']:
        for p in files(CAP / 'metal' / row['id']):
            if p.suffix == '.npy' or p.name in ['clock-inputs.bin', 'clock-inputs.json', 'pressure-trace.json', 'pressure-inputs.json', 'diagnostic-state-hashes.json']:
                pin(p)
    save(ROOT / 'runtime-preparation.json', dict(status='frozen-before-physical-dispatch', revision=revision,
        commands=[r['command'] for r in original['commands']], consumed=consumed, physicalInputs=physical_inputs,
        sourceSnapshots=snapshots, producerSourceSHA256=hashlib.sha256(producer.encode()).hexdigest(),
        linkedMinOS=version[1], linkedSDK=version[2],
        pins={str(p): sha(p) for folder in [runtime, source, helpers] for p in files(folder)},
        host=subprocess.check_output(['sw_vers'], text=True)))
    print('Published release frozen with original producer/resources and linked minOS/SDK15; no physical dispatch')


if __name__ == '__main__': main()
