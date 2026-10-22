"""Exactly three predeclared offline recorder controls, then stop CUDA experiments."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import time

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PARENT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-clock-inputs')
ROOT = PARENT.with_name('2026-10-22-capped-closeout')
DEADLINE = datetime.datetime.fromisoformat('2026-10-22T20:17:50+00:00')


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def save(p, d):
    Path(p).write_text(json.dumps(d, indent=2) + '\n')


def main():
    assert datetime.datetime.now(datetime.timezone.utc) < DEADLINE
    ROOT.mkdir(exist_ok=False)
    began = time.monotonic()
    manifest = json.loads((HERE.parent / PARENT.name / 'archive.json').read_text())['manifest']
    helper = REPO / 'Scripts/cuda/diagnose-phase.py'
    spec = importlib.util.spec_from_file_location('frozen_recurrence', helper)
    model = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(model)
    shutil.copyfile(helper, ROOT / 'diagnose-phase.py')
    shutil.copyfile(__file__, ROOT / 'run.py')
    shutil.copyfile(HERE / 'plan.md', ROOT / 'plan.md')
    inputs, pins, meta = {}, {}, {}
    for mode, sub, stem in [('Metal', 'metal', 'pressure-trace'), ('CUDA', 'capture', 'trace')]:
        folder = PARENT / sub / 'beirut-p0-1'
        for suffix in ['.npy', '.json']:
            p = folder / (stem + suffix)
            assert sha(p) == manifest[str(p.relative_to(PARENT))]['sha256']
            pins[str(p)] = sha(p)
            shutil.copyfile(p, ROOT / (mode + suffix))
        inputs[mode] = np.load(folder / (stem + '.npy'))[:, 0, :]
        meta[mode] = json.loads((folder / (stem + '.json')).read_text())
        assert meta[mode]['columns'] == [187747]
    pins[str(helper)] = sha(helper)

    def recurrence(a, fused):
        x, y, z, w, going = map(float, a[0, 1:6])
        result = np.empty((len(a), 5), dtype='<f4')
        result[0] = [x, y, z, w, going]
        closings = []
        for i in range(1, len(a)):
            p, dt = float(a[i, 0]), float(a[i, 6])
            if dt > 0:
                y = model.fused_sum(max(p, 0), dt, y) if fused else model.f32(y + model.f32(max(p, 0) * dt))
                x = max(x, p)
                if going:
                    if p < 0:
                        going = 0
                        closings.append(i)
                    else:
                        z, w = y, max(w, p)
                if p > 0 and w < .5 * x:
                    z, w, going = y, p, 1
            result[i] = [x, y, z, w, going]
        return result, closings

    baseline = {}
    for mode, a in inputs.items():
        replay, close = recurrence(a, mode == 'Metal')
        assert np.array_equal(replay.view('<u4'), a[:, 1:6].copy().view('<u4')), mode
        baseline[mode] = dict(allRecorderWordsExact=True, samples=len(a),
            closingSamples=close, closingTimes=[meta[mode]['times'][i] for i in close],
            finalPhaseImpulse=float(replay[-1, 2]))
    active = {mode: np.flatnonzero(a[:, 6] > 0) for mode, a in inputs.items()}
    assert len(active['Metal']) == len(active['CUDA']) == 2417
    assert baseline['CUDA']['closingSamples'] == [827]
    assert inputs['CUDA'][827, 0] == np.float32(-.0078125)
    report = dict(status='baseline-qualified', startUTC='2026-10-22T16:17:50Z',
        hardDeadlineUTC=DEADLINE.isoformat(), pins=pins, baseline=baseline,
        experimentCap=3, experiments=[], noGPUJobs=True,
        scope='Offline recurrence sensitivity only. Active-index dt swaps do not align physical states or time axes; no evolved-state or acceptance-policy claim.')
    save(ROOT / 'results.json', report)
    for number, mode, donor in [(1, 'CUDA', 'Metal'), (2, 'Metal', 'CUDA'), (3, 'CUDA', None)]:
        assert datetime.datetime.now(datetime.timezone.utc) < DEADLINE
        a = inputs[mode].copy()
        if donor:
            a[active[mode], 6] = inputs[donor][active[donor], 6]
            changed = 'positive active dt words only, by active index'
            assert np.array_equal(a[:, :6], inputs[mode][:, :6])
            assert np.array_equal(a[:, 7], inputs[mode][:, 7])
        else:
            a[827, 0] = 0
            changed = 'only original CUDA sample827 pressure: -0.0078125 to0 Pa'
            different = np.argwhere(a.view('<u4') != inputs[mode].view('<u4'))
            assert different.tolist() == [[827, 0]]
        replay, close = recurrence(a, mode == 'Metal')
        np.save(ROOT / ('experiment-' + str(number) + '-input.npy'), a)
        np.save(ROOT / ('experiment-' + str(number) + '-recorder.npy'), replay)
        row = dict(number=number, base=mode, dtDonor=donor, changed=changed,
            arithmetic='fused' if mode == 'Metal' else 'separate',
            finalPhaseImpulse=float(replay[-1, 2]),
            deltaFromOwnBaseline=float(replay[-1, 2]) - baseline[mode]['finalPhaseImpulse'],
            closingSamples=close, originalRawTimesAtClosures=[meta[mode]['times'][i] for i in close],
            originalRawTimesAreNotCounterfactualTimes=bool(donor),
            closureWindows=[dict(sample=i, originalTime=meta[mode]['times'][i],
                input=a[max(0, i - 3):i + 4].tolist(),
                recorder=replay[max(0, i - 3):i + 4].tolist()) for i in close])
        report['experiments'].append(row)
        save(ROOT / 'results.json', report)
    for p, digest in pins.items():
        assert sha(p) == digest
    report.update(status='three-experiment-cap-reached-stop', additionalExperiments=3,
        elapsedSeconds=time.monotonic() - began, finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        noMoreCUDAExperimentsAuthorized=True)
    save(ROOT / 'results.json', report)
    shutil.copyfile(ROOT / 'results.json', HERE / 'results.json')
    print(json.dumps(dict(baseline=baseline, experiments=[{k:v for k,v in r.items() if k != 'closureWindows'} for r in report['experiments']], status=report['status']), indent=2))


if __name__ == '__main__':
    main()
