"""Validate actual device clocks and score all target values with the frozen gate."""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

import numpy as np

from clock_model import TICKS, word

HERE = Path(__file__).resolve().parent
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-matched-clock')
BASE = ROOT.parent / '2026-10-22-fixed-terrain-reference'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def main():
    consumed = {}

    def pin(path):
        consumed[str(path)] = sha(path)
        return path

    preflight = load(pin(ROOT / 'preflight.json'))
    for mapping in [preflight['pins'], preflight['consumed']]:
        for path, digest in mapping.items():
            assert sha(path) == digest, path
    assert load(pin(ROOT / 'baseline/receipt.json'))['allBaselineNumericParity']
    receipt = load(pin(ROOT / 'forced/receipt.json'))
    assert receipt['allWorkersTerminal'] and len(receipt['rows']) == 3
    source = pin(BASE / 'recovery/analysis/assemble-saved.py')
    recovery = load(pin(BASE / 'recovery/run.json'))
    assert sha(source) == recovery['sourceSHA256']
    assert len(recovery['controls']) == 3
    assert all(c['wholeControlTargetWordEquality'] for c in recovery['controls'])
    # Reuse the previously validated assembly function verbatim, without executing its controller.
    tree = ast.parse(source.read_text())
    function = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'assemble')
    namespace = {'np': np}
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(source), 'exec'), namespace)
    frozen = load(pin(BASE / 'run.json'))
    comparison_source = pin(BASE / 'analysis/cuda/compare_dataset.py')
    assert sha(comparison_source) == frozen['frozenFiles']['analysis/cuda/compare_dataset.py']['sha256']
    spec = importlib.util.spec_from_file_location('frozen_gate', comparison_source)
    comparator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(comparator)
    rows = []
    for row in receipt['rows']:
        name = row['id']
        assert row['returncode'] == 0, row
        raw = ROOT / 'forced' / name
        for filename, metadata in row['numericFiles'].items():
            if (raw / filename).exists():
                assert sha(pin(raw / filename)) == metadata['sha256']
        plan = load(pin(ROOT / 'cases' / name / 'clock-plan.json'))
        schedule = np.load(pin(ROOT / 'cases' / name / 'metal-dt.npy'), allow_pickle=False)
        actual = np.load(raw / 'dt.npy', allow_pickle=False)
        ledger = load(pin(raw / 'clock-events.json'))
        assert ledger['forced']
        events = ledger['events']
        active = [e for e in events if e['dt'] > 0]
        failures = []
        if not (actual.dtype == schedule.dtype == np.dtype('<f4') and actual.shape == schedule.shape
                and np.array_equal(actual.view(np.uint32), schedule.view(np.uint32))):
            failures.append('dt-history-word-mismatch')
        if len(active) != len(schedule):
            failures.append('active-event-count-mismatch')
        ticks = 0
        for index, (dt, event, metal_time) in enumerate(zip(schedule, active, plan['metalActiveTimes'])):
            ticks += int(float(dt) * TICKS)
            if event['activeBefore'] != index or event['dtWord'] != word(dt):
                failures.append(['active-index-or-dt', index])
            if event['clockTicks'] != ticks:
                failures.append(['relative-device-ticks', index])
            if (event['clockTicks'] + plan['metalOriginTick']) / TICKS != metal_time:
                failures.append(['absolute-metal-ticks', index])
        expected = plan['model']['events']
        if len(expected) != len(events):
            failures.append('batch-event-count-mismatch')
        for index, (a, b) in enumerate(zip(events, expected)):
            for key in ['dtWord', 'clockTicks', 'stopped', 'stepIndex']:
                if a[key] != b[key]:
                    failures.append(['batch-model', index, key])
            if word(a['batchTime']) != word(b['batchTime']):
                failures.append(['batch-model', index, 'batchTime'])
        assert events[-1]['stopped'] == 2
        ref = BASE / 'cases' / name / 'metal'
        template = BASE / 'recovery/control' / name / 'input'
        mask = np.load(pin(ref / 'mask.npy'), allow_pickle=False)
        native_mask = np.load(raw / 'mask.npy', allow_pickle=False)
        assert mask.shape == native_mask.shape and np.all(native_mask[mask != 0] != 0)
        for filename in ['inputs.npy', 'mask.npy']:
            assert sha(pin(ref / filename)) == sha(pin(template / filename))
        assert sha(pin(template / 'columns.bin')) == sha(pin(BASE / 'cases' / name / 'input/columns.bin'))
        pin(ref / 'targets.npy')
        dataset = ROOT / 'datasets' / name
        dataset.mkdir(parents=True, exist_ok=False)
        np.save(dataset / 'targets.npy', namespace['assemble'](raw, mask))
        for filename in ['inputs.npy', 'mask.npy']:
            shutil.copyfile(ref / filename, dataset / filename)
        comparison = comparator.compare(ref, dataset)
        target = np.load(dataset / 'targets.npy', allow_pickle=False)
        reference = np.load(ref / 'targets.npy', allow_pickle=False)
        errors = []
        for channel in range(3):
            delta = np.abs(target[channel].astype(np.float64) - reference[channel])
            bad = (mask != 0) & (delta > .05 + .002 * np.abs(reference[channel].astype(np.float64)))
            for y, x in np.argwhere(bad):
                errors.append(dict(channel=channel, row=int(y), column=int(x),
                    reference=float(reference[channel, y, x]), candidate=float(target[channel, y, x]),
                    absoluteError=float(delta[y, x]), allowance=float(.05 + .002 * abs(float(reference[channel, y, x])))))
        (dataset / 'failures.json').write_text(json.dumps(errors, indent=2) + '\n')
        histories = {}
        metal_bank = ROOT.parent / '2026-10-22-metal-pressure-inputs/cases' / name / 'inputs'
        for kind, folder, npy_name, json_name in [
            ('nativeCUDA', ROOT / 'baseline' / name, 'trace.npy', 'trace.json'),
            ('matchedClockCUDA', raw, 'trace.npy', 'trace.json'),
            ('nativeMetal', metal_bank, 'pressure-trace.npy', 'pressure-trace.json'),
        ]:
            trace = np.load(pin(folder / npy_name), allow_pickle=False)
            metadata = load(pin(folder / json_name))
            transitions = []
            for q, column in enumerate(metadata['columns']):
                changes = np.flatnonzero(trace[1:, q, 5] != trace[:-1, q, 5]) + 1
                transitions.append(dict(column=column, finalImpulse=float(trace[-1, q, 3]),
                    changes=[dict(sample=int(i), rawTime=metadata['times'][int(i)],
                        pressure=float(trace[i, q, 0]), open=float(trace[i, q, 5]),
                        impulse=float(trace[i, q, 3])) for i in changes]))
            histories[kind] = transitions
        rows.append(dict(id=name, clockPassed=not failures, clockFailures=failures,
            activeSteps=len(active), inactiveEvents=len(events)-len(active),
            rawOriginMinusTickOrigin=plan['rawOriginMinusTickOrigin'],
            comparison=comparison, failureCount=len(errors), selectedNativeHistories=histories,
            packaging='Previously validated saved-output assembly; exact shared reference features/masks; native mask covers every valid reference receiver'))
    for path, digest in consumed.items():
        assert sha(path) == digest, path
        if Path(path).is_relative_to(BASE):
            archive = load(HERE.parent / '2026-10-22-fixed-terrain-reference/pilot-archive.json')['files']
            assert digest == archive[str(Path(path).relative_to(BASE))]['sha256'], path
    result = dict(status='complete-all-outcomes', rows=rows, consumed=consumed,
        sourceSHA256=sha(__file__), allClocksPass=all(r['clockPassed'] for r in rows),
        allTargetsPass=all(r['comparison']['passed'] for r in rows),
        defaultBulkGeneration='held; controlled reference-dependent clock experiment only')
    (ROOT / 'analysis-result.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.copyfile(__file__, ROOT / 'analysis/analyze.py')
    print(json.dumps({k: v for k, v in result.items() if k != 'consumed'}, indent=2))


if __name__ == '__main__':
    main()
