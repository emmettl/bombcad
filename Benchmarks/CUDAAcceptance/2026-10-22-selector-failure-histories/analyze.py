"""Describe parity-qualified histories on their own unmodified time axes."""
import json

import numpy as np

from prepare import ROOT, load, save


def main():
    assert load(ROOT / 'verification.json')['allFourExpandedGatesPass']
    result = dict(rows=[], interpretation={
        'slope': 'Test the existing strict half-peak qualification, including reopening; do not infer a near-zero closure from the final impulse gap.',
        'Beirut': 'pressure-trace peak is recorder max of interpolated pressure. Target channel0 interpolates per-cell accumulated peak buffers. These are distinct; recorder maxima do not explain the target peak failures by themselves.',
        'scope': 'Selected receivers only; distinct native time axes, no identical-state assertion, no tolerance/phase/reference change.'})
    for mode in ['original', 'selector']:
        for name in ['made-perimeter-s3-1', 'beirut-p0-1']:
            folder = ROOT / mode / name
            meta = load(folder / 'pressure-trace.json')
            trace = np.load(folder / 'pressure-trace.npy')
            targets = np.load(folder / 'targets.npy').reshape(3, -1)
            mask = np.load(folder / 'mask.npy').reshape(-1)
            for j, column in enumerate(meta['columns']):
                a = trace[:, j]

                def sample(i):
                    return dict(index=int(i), step=meta['steps'][i], time=meta['times'][i], values=a[i].tolist())

                def window(i):
                    return [sample(k) for k in range(max(0, i - 3), min(len(a), i + 4))]

                transitions = np.flatnonzero(a[1:, 5] != a[:-1, 5]) + 1
                maximum = int(np.argmax(a[:, 0]))
                negative = np.flatnonzero(a[:, 0] < 0)
                local = np.flatnonzero((a[1:-1, 0] > a[:-2, 0]) & (a[1:-1, 0] >= a[2:, 0])) + 1
                local = sorted(local, key=lambda i: float(a[i, 0]), reverse=True)[:10]
                assert mask[column] == 1
                assert a[-1, 3].view('<u4') == targets[2, column].view('<u4')
                row = dict(mode=mode, id=name, column=column, fields=meta['fields'],
                    rawTimesPreserved=True, samples=len(a), targetValues=targets[:, column].tolist(),
                    finalRecorder=sample(len(a) - 1), phaseTargetWordExact=True,
                    firstNegative=sample(int(negative[0])) if len(negative) else None,
                    transitions=[dict(before=sample(int(i - 1)), after=sample(int(i)), window=window(int(i))) for i in transitions],
                    pressureMaximum=dict(sample=sample(maximum), window=window(maximum)),
                    largestLocalPressureMaxima=[sample(int(i)) for i in local],
                    recorderPeakMinusTargetPeak=float(a[-1, 1]) - float(targets[0, column]))
                if column == 244192:
                    # These Float32 values are exactly representable in Double here.
                    retained = float(a[2243, 4])
                    peak = float(a[-1, 1])
                    row['halfPeakDecision'] = dict(retainedFirstPhasePeak=retained,
                        finalRecorderPeak=peak, halfFinalPeak=peak / 2,
                        retainedMinusHalf=retained - peak / 2,
                        strictRequalification=retained < peak / 2,
                        rowsAroundSecondPeak=window(maximum))
                result['rows'].append(row)
    save(ROOT / 'histories.json', result)
    print(json.dumps([dict(mode=r['mode'], id=r['id'], column=r['column'],
        target=r['targetValues'], transitions=[x['after']['index'] for x in r['transitions']],
        halfPeakDecision={k:v for k,v in r.get('halfPeakDecision', {}).items() if k != 'rowsAroundSecondPeak'},
        recorderPeakMinusTargetPeak=r['recorderPeakMinusTargetPeak']) for r in result['rows']], indent=2))


if __name__ == '__main__':
    main()
