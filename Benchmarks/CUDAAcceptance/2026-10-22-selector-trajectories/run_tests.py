"""Bounded owned diagnostic controls; each named stage retains its sole outcome."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-selector-trajectories')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''): h.update(b)
    return h.hexdigest()


def save(path, value): Path(path).write_text(json.dumps(value, indent=2) + '\n')


def main():
    p = argparse.ArgumentParser(); p.add_argument('stage', choices=['focused', 'banks', 'analytic'])
    stage = p.parse_args().stage
    ROOT.mkdir(exist_ok=True); validation = ROOT / 'validation'; validation.mkdir(exist_ok=True)
    receipt = validation / (stage + '-process.json')
    assert not receipt.exists(), 'Observe existing stage; do not duplicate numerical controls'
    deadline = time.monotonic() + 5400
    if stage == 'analytic':
        assert not (ROOT / 'analytic').exists()
        bank_result = json.loads((ROOT / 'native-banks/bank-results.json').read_text())
        assert len(bank_result) == 12 and all(r['allWordsExact'] for r in bank_result)
        banks = ROOT / 'native-banks'
        prep = json.loads((banks / 'bank-preparation.json').read_text())
        for path, digest in prep['pins'].items(): assert sha(path) == digest, path
        expected_keys = {(mode, row['label']) for mode in ['baseline', 'precise'] for row in prep['rows']}
        assert {(r['mode'], r['label']) for r in bank_result} == expected_keys
        for r in bank_result:
            row = next(row for row in prep['rows'] if row['label'] == r['label'])
            actual = banks / (r['mode'] + '-' + r['label'] + '.bin')
            expected = banks / row['folder'] / ('expected-' + r['mode'] + '.bin')
            assert sha(actual) == r['sha256'] == sha(expected)
            assert r['words'] == row['frames'] * 24
    build_command = ['swift', 'build', '--build-tests']
    with (validation / (stage + '-build.log')).open('xb') as log:
        build = subprocess.run(build_command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, timeout=max(1, deadline-time.monotonic()))
    executable = REPO / '.build/debug/BlastCoreTests.xctest/Contents/MacOS/BlastCoreTests'
    build_report = dict(command=build_command, returncode=build.returncode)
    if build.returncode == 0:
        linked = subprocess.check_output(['otool', '-l', str(executable)], text=True)
        (validation / (stage + '-linked-sdk.txt')).write_text(linked)
        version = re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([\d.]+)\s+sdk ([\d.]+)', linked)
        assert version is not None
        build_report.update(binarySHA256=sha(executable), linkedMinOS=version[1], linkedSDK=version[2])
    save(validation / (stage + '-build.json'), build_report)
    assert build.returncode == 0, 'Retained compile-only failure; no GPU dispatch'
    assert build_report['linkedMinOS'] == build_report['linkedSDK'] == '15.0'
    runtime = validation / (stage + '-runtime'); runtime.mkdir(exist_ok=False)
    shutil.copytree(executable.parents[2], runtime / 'BlastCoreTests.xctest')
    for name in ['BombCAD_BlastCore.bundle', 'ContinuumKit_ContactSearchMetal.bundle']:
        shutil.copytree(REPO / '.build/debug' / name, runtime / name)
    source = runtime / 'sources'; source.mkdir()
    snapshots = []
    chosen = sorted((REPO / 'Sources/BlastCore').glob('*.swift'))
    chosen += sorted((REPO / 'Sources/BlastCore/Shaders').glob('*.metal'))
    chosen += sorted((REPO / 'Tests/BlastCoreTests').glob('StepSelector*Tests.swift'))
    for i, path in enumerate(chosen):
        dest = source / (f'{i:04d}-' + path.name); shutil.copyfile(path, dest)
        snapshots.append(dict(original=str(path), snapshot=str(dest), sha256=sha(dest)))
    env = os.environ.copy()
    for key in list(env):
        if key.startswith('BOMBCAD_KERNEL_') or key in ['BOMBCAD_STATE_PADDING', 'BOMBCAD_STATE_PADDING_AT', 'PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL']:
            env.pop(key)
    env['BOMBCAD_SETTLE_CACHE'] = '/Volumes/StudioData/bombcad/settle-cache'
    suite = dict(focused='StepSelectorDiagnosticsTests', banks='StepSelectorBankReplayTests', analytic='StepSelectorAnalyticTests')[stage]
    if stage == 'banks': env['BOMBCAD_SELECTOR_BANKS'] = str(ROOT / 'native-banks')
    if stage == 'analytic': env['BOMBCAD_SELECTOR_ANALYTIC_OUT'] = str(ROOT / 'analytic')
    command = [str(Path.home() / '.local/bin/gpu-slot'), '--mem', '2', 'swift', 'test', '--skip-build', '--filter', suite]
    with (validation / (stage + '.log')).open('xb') as log:
        proc = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        report = dict(status='running', stage=stage, pid=proc.pid, command=command,
            binarySHA256=build_report['binarySHA256'], snapshots=snapshots,
            revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip())
        save(receipt, report)
        try: code = proc.wait(timeout=max(1, deadline-time.monotonic()))
        except subprocess.TimeoutExpired:
            if proc.poll() is None: os.killpg(proc.pid, signal.SIGTERM)
            try: code = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                if proc.poll() is None: os.killpg(proc.pid, signal.SIGKILL)
                code = proc.wait()
            report['timedOut'] = True
        report.update(status='terminal', returncode=code)
        report['sourcesUnchangedDuringRun'] = all(sha(r['original']) == sha(r['snapshot']) == r['sha256'] for r in snapshots)
        report['binaryUnchangedDuringRun'] = sha(executable) == report['binarySHA256']
        save(receipt, report)
        assert report['sourcesUnchangedDuringRun'] and report['binaryUnchangedDuringRun']
    print(stage, 'terminal', code)
    if code: print((validation / (stage + '.log')).read_text())
    raise SystemExit(code)


if __name__ == '__main__': main()
