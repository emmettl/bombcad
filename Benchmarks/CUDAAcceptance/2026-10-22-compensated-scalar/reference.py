"""Explicit operation-rounded Float32 scalar oracle; no GPU-instruction claim."""
import json
import math
from pathlib import Path
import struct
import sys


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def value(word):
    return struct.unpack('<f', struct.pack('<I', word))[0]


def f32(number):
    return value(bits(number))


def fixtures():
    density = f32(1.225)
    energy = 253314.546875
    definitions = [
        ('density-positive', density, [2**-27] * 4096, {}),
        ('density-negative', density, [-2**-27] * 4096, {}),
        ('energy-negative', energy, [-2**-12] * 4096, {}),
        ('energy-sign-reversal', energy, ([-2**-12] * 1024 + [2**-12] * 1024) * 2, {}),
        ('signed-zeros', 0., [0., -0.] * 1024, {}),
        ('large-cancellation', 1., [2**24, 1., -2**24] * 64, {}),
        ('cross-zero', 2**-10, ([-2**-12] * 8 + [2**-12] * 8) * 128, {}),
        ('density-reset', density, [2**-27] * 4096,
         {'1024': bits(density), '2048': bits(density), '3072': bits(density)}),
    ]
    return {'schema': 'bombcad-compensated-scalar-input-1', 'sequences': [
        dict(name=name, initial=bits(initial), deltas=[bits(d) for d in deltas], resets=resets)
        for name, initial, deltas, resets in definitions]}


def reference(sequence, compensated):
    total, error = value(sequence['initial']), 0.
    anchor = total
    increments = []
    trace, targets = [], []
    for step, word in enumerate(sequence['deltas']):
        if str(step) in sequence['resets']:
            total, error = value(sequence['resets'][str(step)]), 0.
            anchor, increments = total, []
        delta = value(word)
        if compensated:
            corrected = f32(delta - error)
            updated = f32(total + corrected)
            error = f32(f32(updated - total) - corrected)
            total = updated
        else:
            total = f32(total + delta)
        increments.append(delta)
        trace += [bits(total), bits(error)]
        targets.append(math.fsum([anchor, *increments]))
    return trace, targets


def audit(fixture_path, result_path, output_path):
    fixture = json.loads(Path(fixture_path).read_text())
    assert fixture == fixtures(), 'fixture differs from fixed predeclared definitions'
    results = json.loads(Path(result_path).read_text())['results']
    assert len(results) == 18
    by_key = {(r['policy'], r['method'], r['observed']): r for r in results}
    assert len(by_key) == 18
    rows = []
    for policy in ['default', 'unfused', 'safe-unfused']:
        for method in ['naive', 'kahan', 'protected-kahan']:
            observed = by_key[policy, method, True]
            plain = by_key[policy, method, False]
            assert len(plain['finalWords']) == len(fixture['sequences']) * 2
            assert len(observed['traceWords']) == sum(len(s['deltas']) for s in fixture['sequences']) * 2
            offset = 0
            for index, sequence in enumerate(fixture['sequences']):
                expected, targets = reference(sequence, method != 'naive')
                actual = observed['traceWords'][offset:offset + len(expected)]
                offset += len(expected)
                final = observed['finalWords'][index * 2:index * 2 + 2]
                assert final == actual[-2:], 'trace final differs from own final buffer'
                total, error = map(value, final)
                rows.append(dict(policy=policy, method=method, case=sequence['name'],
                    steps=len(targets), traceWordDifferences=sum(a != b for a, b in zip(actual, expected)),
                    finalWords=final, cpuFinalWords=expected[-2:],
                    observationParity=final == plain['finalWords'][index * 2:index * 2 + 2],
                    finalStored=total, finalResidual=error, finalTarget=targets[-1],
                    finalStoredError=total-targets[-1], finalCorrectedError=(total-error)-targets[-1],
                    maximumStoredAbsoluteError=max(abs(value(actual[2*i])-target) for i,target in enumerate(targets)),
                    maximumCorrectedAbsoluteError=max(abs((value(actual[2*i])-value(actual[2*i+1]))-target) for i,target in enumerate(targets))))
    protected = [r for r in rows if r['method'] == 'protected-kahan']
    report = dict(status='complete', dispatches=18, sequences=8, rows=rows,
        protectedAllCPUWordsMatch=all(r['traceWordDifferences'] == 0 for r in protected),
        protectedAllObservationParity=all(r['observationParity'] for r in protected),
        limits='Finite scalar fixtures; not PDE accuracy, emitted instructions, arbitrary compiler programs or solver clamp/restart validation.')
    Path(output_path).write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k != 'rows'},indent=2))


if __name__ == '__main__':
    if sys.argv[1] == 'fixtures':
        Path(sys.argv[2]).write_text(json.dumps(fixtures(),separators=(',',':'))+'\n')
    elif sys.argv[1] == 'audit':
        audit(*sys.argv[2:])
    else:
        raise SystemExit('reference.py fixtures FILE | audit FIXTURE RESULTS REPORT')
