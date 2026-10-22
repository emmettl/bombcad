"""Verify full scalar controls and independently recompute analytic bounds from saved states."""
import json
import math
from pathlib import Path

import numpy as np

from run_tests import HERE, REPO, ROOT, save, sha


def load(p): return json.loads(Path(p).read_text())


def sod_density(x, t):
    gamma = 1.4; sound_left = math.sqrt(gamma); xi = (x - .5) / t
    if xi < -sound_left: return 1.
    if xi < -.07027:
        velocity = 2 / (gamma + 1) * (sound_left + xi)
        sound = sound_left - .5 * (gamma - 1) * velocity
        return math.pow(sound / sound_left, 2 / (gamma - 1))
    if xi < .92745: return .42632
    if xi < 1.75216: return .26557
    return .125


def main():
    consumed = {}
    def pin(p): consumed[str(p)] = sha(p); return p
    validation = ROOT / 'validation'
    for stage in ['focused', 'banks', 'analytic']:
        p = load(pin(validation / (stage + '-process.json')))
        assert p['status'] == 'terminal' and p['returncode'] == 0 and not p.get('timedOut')
        build = load(pin(validation / (stage + '-build.json')))
        assert build['returncode'] == 0 and build['linkedSDK'] == build['linkedMinOS'] == '15.0'
    preserved = validation / 'first-executed-build'
    first = load(pin(preserved / 'receipt.json'))
    for name, digest in first['files'].items(): assert sha(pin(preserved / name)) == digest
    analytic_process = load(validation / 'analytic-process.json')
    assert analytic_process['sourcesUnchangedDuringRun'] and analytic_process['binaryUnchangedDuringRun']
    for snapshot in analytic_process['snapshots']: assert sha(pin(Path(snapshot['snapshot']))) == snapshot['sha256']
    executable = validation / 'analytic-runtime/BlastCoreTests.xctest/Contents/MacOS/BlastCoreTests'
    assert sha(pin(executable)) == analytic_process['binarySHA256']
    bank = ROOT / 'native-banks'; prep = load(pin(bank / 'bank-preparation.json'))
    for p, h in prep['pins'].items(): assert sha(pin(Path(p))) == h
    original_parents = load(bank / 'parent-pins.json')['consumed']
    for p, h in original_parents.items(): assert sha(pin(Path(p))) == h
    bank_result = load(pin(bank / 'bank-results.json'))
    assert len(bank_result) == 12
    words = dict(baseline=0, precise=0)
    for row in bank_result:
        original = next(r for r in prep['rows'] if r['label'] == row['label'])
        actual = bank / (row['mode'] + '-' + row['label'] + '.bin')
        expected = bank / original['folder'] / ('expected-' + row['mode'] + '.bin')
        assert sha(pin(actual)) == row['sha256'] == sha(pin(expected))
        assert row['words'] == original['frames'] * 24 and row['allWordsExact']
        words[row['mode']] += row['words']
    assert words == dict(baseline=375672, precise=375672)
    metrics = load(pin(ROOT / 'analytic/metrics.json')); assert len(metrics) == 12
    rows = []; initial_by_case = {}
    for r in metrics:
        n = r['cells']; folder = ROOT / 'analytic' / r['id']
        arrays = {stage: np.fromfile(pin(folder / (stage + '.bin')), dtype='<f4').reshape(r['shape'])
                  for stage in ['initial', 'final']}
        assert all(np.isfinite(a).all() for a in arrays.values())
        key = (r['problem'], n, r.get('riemann'))
        initial_hash = sha(folder / 'initial.bin')
        if key in initial_by_case: assert initial_hash == initial_by_case[key]
        else: initial_by_case[key] = initial_hash
        dx = float(np.float32(1) / np.float32(n))
        measure = dx if r['problem'] == 'sod' else math.pow(dx, 3)
        actual_totals = {}
        for stage, a in arrays.items():
            flat = a.reshape(-1, 5)
            actual_totals[stage] = dict(mass=sum(map(float, flat[:, 0])) * measure,
                energy=sum(map(float, flat[:, 4])) * measure)
            for field in ['mass', 'energy']:
                assert math.isclose(actual_totals[stage][field], r[stage + 'Totals'][field], rel_tol=1e-12)
        item = dict(id=r['id'], problem=r['problem'], cells=n, preciseSelector=r['preciseSelector'],
            riemann=r.get('riemann'), stable=r['stable'], steps=r['steps'], time=r['time'], totals=actual_totals,
            relativeConservationChange={k: actual_totals['final'][k] / actual_totals['initial'][k] - 1 for k in ['mass', 'energy']})
        if r['problem'] == 'sod':
            a = arrays['final'].reshape(n, 5)
            error = sum(abs(float(a[i, 0]) - sod_density((i + .5) / n, r['time'])) for i in range(n)) / n
            passed = r['stable'] and abs(r['time'] - .2) < 1e-5 and error < .004
            item.update(recomputedDensityL1=error, recordedDensityL1=r['densityL1'])
        else:
            a = arrays['final']
            radii = []
            for direction in [(1, 0, 0), (1, 1, 1)]:
                indices = [i for i in range(n) if a[i * direction[2], i * direction[1], i * direction[0], 0] > 2]
                front = max(indices, default=0)
                length = np.float32(math.sqrt(sum(x*x for x in direction)))
                radii.append(float(np.float32(np.float32(np.float32(front) + np.float32(.5)) * np.float32(dx)) * length))
            errors = [abs(x - .6) / .6 for x in radii]
            peak = float(a[0, 0, :, 0].max())
            passed = r['stable'] and all(x < .04 for x in errors) and 2.5 < peak < 6.5
            item.update(recomputedRadii=radii, recomputedRadiusRelativeErrors=errors, peakDensity=peak)
        assert passed and r['passed'], r['id']
        item['passed'] = passed; rows.append(item)
    refinement = []
    for problem, sizes in [('sod', [400, 800]), ('sedov', [80, 120])]:
        for precise in [False, True]:
            for riemann in ([0, 1] if problem == 'sod' else [None]):
                pair = [next(r for r in rows if r['problem'] == problem and r['cells'] == n
                        and r['preciseSelector'] == precise and r['riemann'] == riemann) for n in sizes]
                if problem == 'sod': errors = [p['recomputedDensityL1'] for p in pair]
                else: errors = [max(p['recomputedRadiusRelativeErrors']) for p in pair]
                refinement.append(dict(problem=problem, preciseSelector=precise, riemann=riemann,
                    sizes=sizes, errors=errors, improved=errors[1] < errors[0]))
    report = dict(status='verified-controls-only', nativeBankWords=words, analyticRuns=len(rows),
        allIndependentOriginalBoundsPass=True, rows=rows, refinement=refinement, consumed=consumed,
        sourceSHA256=sha(__file__),
        limits='Same predeclared analytic bounds; Double conservation sums checked for host aggregation agreement only. No district pilot/full target acceptance yet. Early focused/bank sources preserved post-terminal against executed binary hashes; analytic sources/resources snapshotted before dispatch. No numerical retry or production policy change.')
    save(ROOT / 'control-audit.json', report)
    print(json.dumps({k: v for k, v in report.items() if k not in ['consumed', 'rows']}, indent=2))


if __name__ == '__main__': main()
