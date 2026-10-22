"""One declared district stage, with immutable runtime and strict parity gates; no retries."""
import argparse
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from selector_runtime_prepare import ROOT, CAP, sha, load, save, files


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('stage', choices=['baseline', 'plain', 'capture'])
    stage = parser.parse_args().stage
    prep = load(ROOT / 'runtime-preparation.json')
    report_path = ROOT / ('pilots-' + stage + '.json'); assert not report_path.exists(), 'Observe existing stage; no numerical retry'
    if stage != 'baseline': assert load(ROOT / 'pilots-baseline.json')['allThreeParityGatesPass']
    if stage == 'capture': assert load(ROOT / 'pilots-plain.json')['allThreeRunsComplete']
    helpers = ROOT / 'analysis/qhelpers'; sys.path.insert(0, str(helpers))
    spec = importlib.util.spec_from_file_location('frozen_queue_helpers', helpers / 'field-queue.py')
    q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
    pins = dict(prep['pins']); pins[str(Path(__file__))] = sha(__file__)
    consumed = dict(prep['consumed']); consumed.update(prep['physicalInputs'])
    report = dict(status='running', stage=stage, revision=prep['revision'], controllerPID=os.getpid(),
        boot=q.boot_id(), pins=pins, consumed=consumed, rows=[], commands=[])
    def persist(): q.atomic(report_path, report)
    def verify():
        for mapping in [pins, consumed]:
            for p, h in mapping.items(): assert sha(p) == h, p
    env = q.clean_env(dict(slotEnvironment={}, revisionObservedAtInit=prep['revision'], worktreeDirtyAtInit=False))
    for key in ['PACKAGE_RESOURCE_BUNDLE_PATH', 'PACKAGE_RESOURCE_BUNDLE_URL']:
        env.pop(key, None)
    deadline = time.monotonic() + 5400
    persist()
    try:
        for original in prep['commands']:
            name = original[original.index('--id') + 1]
            output = ROOT / stage / name; output.parent.mkdir(exist_ok=True)
            assert not output.exists()
            args = []; it = iter(original[4:])
            for key in it:
                if key == '--out': next(it)
                elif stage == 'plain' and key == '--trace-columns': next(it)
                elif stage == 'plain' and key in ['--trace-pressure', '--trace-pressure-inputs', '--trace-clock-inputs']: pass
                else: args.append(key)
            command = [original[0], '--mem', original[2], str(ROOT / 'runtime-metal/scenebench'), *args]
            if stage != 'baseline': command.append('--precise-step-selector-diagnostic')
            command += ['--out', str(output)]
            verify()
            with (ROOT / (stage + '-' + name + '.log')).open('xb') as log:
                proc = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                identity = q.process_snapshot(proc.pid)
                entry = dict(pid=proc.pid, boot=q.boot_id(), identity=identity, command=command)
                report['liveProcess'] = entry; persist()
                def same():
                    actual = q.process_snapshot(proc.pid)
                    return q.boot_id() == entry['boot'] and actual is not None and identity is not None and actual['birth'] == identity['birth'] and actual['command'] == identity['command']
                try: code = proc.wait(timeout=max(1, deadline-time.monotonic()))
                except subprocess.TimeoutExpired:
                    assert same(); os.killpg(proc.pid, signal.SIGTERM)
                    try: code = proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        assert same(); os.killpg(proc.pid, signal.SIGKILL); code = proc.wait()
                    entry['timedOut'] = True
                entry['returncode'] = code
            entry['ownedGroupTerminal'] = not q.group_alive(proc.pid)
            report['commands'].append(entry); report.pop('liveProcess'); persist()
            row = dict(id=name, returncode=code, status='worker-failed'); report['rows'].append(row); persist()
            assert code == 0 and entry['ownedGroupTerminal'], row
            numeric = {p.name: sha(p) for p in output.glob('*.npy')}
            state = load(output / 'diagnostic-state-hashes.json')
            if stage == 'baseline':
                expected = CAP / 'metal' / name
                wanted = {p.name: sha(p) for p in expected.glob('*.npy')}
                row.update(allOriginalNumericBytesEqual=numeric == wanted,
                    metadataParity={n: (output / n).read_bytes() == (expected / n).read_bytes()
                                    for n in ['clock-inputs.json', 'pressure-trace.json', 'pressure-inputs.json', 'diagnostic-state-hashes.json']},
                    clockWordsExact=sha(output / 'clock-inputs.bin') == sha(expected / 'clock-inputs.bin'))
                passed = row['allOriginalNumericBytesEqual'] and all(row['metadataParity'].values()) and row['clockWordsExact']
                assert not (output / 'step-selector.json').exists()
            else:
                selector = load(output / 'step-selector.json')
                assert selector['sourceSHA256'] == prep['producerSourceSHA256'] and selector['entryPoint'] == 'prepareStep'
                assert selector['mathMode'] == 'safe' and selector['mathFloatingPointFunctions'] == 'precise'
                baseline = ROOT / 'baseline' / name
                old_state = load(baseline / 'diagnostic-state-hashes.json')
                row.update(initialStateHashesExact=state['initial'] == old_state['initial'],
                    initialTimeExact=state['initialTime'] == old_state['initialTime'],
                    featuresMasksExact=all(sha(output / n) == sha(baseline / n) for n in ['inputs.npy', 'mask.npy']))
                passed = row['initialStateHashesExact'] and row['initialTimeExact'] and row['featuresMasksExact']
                assert load(output / 'meta.json')['stable'] is True
                if stage == 'capture':
                    plain = ROOT / 'plain' / name
                    common = {p.name: sha(p) for p in plain.glob('*.npy')}
                    row.update(allPlainNumericBytesEqual=all(numeric.get(n) == h for n, h in common.items()),
                        completeStateHashesExact=(output / 'diagnostic-state-hashes.json').read_bytes() == (plain / 'diagnostic-state-hashes.json').read_bytes())
                    passed = passed and row['allPlainNumericBytesEqual'] and row['completeStateHashesExact']
                else:
                    assert set(numeric) == {'inputs.npy', 'mask.npy', 'targets.npy'}
            row.update(status='parity-pass' if passed else 'parity-failed', numericFilesSHA256=numeric,
                fullFiles={str(p.relative_to(output)): dict(sha256=sha(p), bytes=p.stat().st_size) for p in files(output)})
            persist(); assert passed, 'Retained physical parity failure; no retry or observer adjustment'
        verify()
        report.update(status='complete-all-outcomes', allThreeRunsComplete=len(report['rows']) == 3,
            allThreeParityGatesPass=len(report['rows']) == 3 and all(r['status'] == 'parity-pass' for r in report['rows']),
            allOwnedGroupsTerminal=all(r['ownedGroupTerminal'] for r in report['commands']))
    except BaseException as error:
        report.update(status='stopped', error=repr(error)); persist(); raise
    persist()
    print(stage, 'complete; all three gates pass; owned groups terminal')


if __name__ == '__main__': main()
