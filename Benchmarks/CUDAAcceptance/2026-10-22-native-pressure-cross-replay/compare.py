"""Native reader/input matrix; exact diagonal gates precede conditional phases."""
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from analyze import replay

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-native-pressure-cross-replay')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def main():
    assert load(ROOT / 'metal-own-gate.json')['status'] == load(ROOT / 'cuda-own-gate.json')['status'] == 'pass'
    metal_own, metal_cross = [load(ROOT / p) for p in ['metal-own-receipt.json', 'metal-cross-receipt.json']]
    cuda_own, cuda_cross = [load(ROOT / p) for p in ['cuda-own/receipt.json', 'cuda-cross/receipt.json']]
    assert metal_own['sourceSHA256'] == metal_cross['sourceSHA256'] == sha(ROOT / 'analysis/producer-library.metal')
    assert metal_own['binarySHA256'] == metal_cross['binarySHA256'] == sha(ROOT / 'runtime/replay')
    assert cuda_own['ownInputGatePass']
    assert cuda_own['diagnosticSourceSHA256'] == cuda_cross['diagnosticSourceSHA256']
    assert cuda_own['compile'] == cuda_cross['compile'] and cuda_own['selectedRuntimePins'] == cuda_cross['selectedRuntimePins']
    assert cuda_own['device'] == cuda_cross['device'] and cuda_own['architecture'] == cuda_cross['architecture']
    for stage in ['own', 'cross']:
        assert load(ROOT / ('cuda-' + stage + '-controller.json'))['returncode'] == 0
        assert load(ROOT / ('metal-' + stage + '-process.json'))['returncode'] == 0
    consumed = {}
    for mapping in [load(ROOT / 'preparation.json')['pins'], load(ROOT / 'cuda-staging.json')['pins']]:
        for path, digest in mapping.items():
            assert sha(path) == digest, path
            consumed[path] = digest

    def read(path, dtype='<f4'):
        consumed[str(path)] = sha(path)
        return np.fromfile(path, dtype=dtype)

    def metadata(path):
        consumed[str(path)] = sha(path)
        return load(path)

    for path in [Path(__file__), Path(__file__).with_name('analyze.py'),
                 Path(__file__).with_name('pressure_model.py'), Path(sys.executable).resolve(),
                 Path(np._core._multiarray_umath.__file__), ROOT / 'metal-own-receipt.json',
                 ROOT / 'metal-cross-receipt.json', ROOT / 'cuda-own/receipt.json', ROOT / 'cuda-cross/receipt.json']:
        consumed[str(path)] = sha(path)
    banks = []
    # Every diagonal recorder word is checked before a cross-reader phase is interpreted.
    for backend, manifest in [('metal', 'metal-own.json'), ('cuda', 'metal-cross.json')]:
        for item in metadata(ROOT / manifest)['cases']:
            folder = Path(item['folder'])
            frames, columns = item['frames'], item['columns']
            info = metadata(folder / 'times-and-seeds.json')
            expected = read(folder / 'expected-pressure.bin').reshape(frames, len(columns))
            records = read(folder / 'records-after.bin').reshape(frames, len(columns), 5)
            dt = read(folder / 'controls.bin').reshape(frames, -1)[:, 0]
            pressures = {
                'metal': read(folder / 'metal-pressure.bin').reshape(frames, len(columns)),
                'cuda': read(ROOT / ('cuda-cross' if backend == 'metal' else 'cuda-own') / item['label'] / 'pressure.bin').reshape(frames, len(columns)),
            }
            for reader, array in pressures.items():
                assert np.isfinite(array).all()
                receipt = (metal_own if backend == 'metal' else metal_cross) if reader == 'metal' else (cuda_cross if backend == 'metal' else cuda_own)
                row = next(x for x in receipt['rows'] if x['label'] == item['label'])
                path = folder / 'metal-pressure.bin' if reader == 'metal' else ROOT / ('cuda-cross' if backend == 'metal' else 'cuda-own') / item['label'] / 'pressure.bin'
                assert sha(path) == row['outputSHA256' if reader == 'metal' else 'pressureSHA256']
            assert np.array_equal(pressures[backend].view(np.uint32), expected.view(np.uint32))
            policy = 'fused' if backend == 'metal' else 'separate'
            native = []
            for q, column in enumerate(columns):
                result = replay(expected[:, q], dt, info['seeds'][q], info['times'], policy, records[:, q])
                assert result['recordWordDifferences'] == 0, (item['label'], column)
                native.append(result)
            banks.append(dict(item=item, backend=backend, times=info['times'], seeds=info['seeds'],
                              dt=dt, pressures=pressures, native=native, policy=policy))
    rows = []
    for bank in banks:
        item, backend = bank['item'], bank['backend']
        name = item['label'].rsplit('-', 1)[0]
        metal_bank = next(b for b in banks if b['item']['label'] == name + '-metal')
        columns = []
        for q, column in enumerate(item['columns']):
            native = bank['pressures'][backend][:, q]
            ref = metal_bank['native'][q]['final'][2]
            readers = {}
            for reader, array in bank['pressures'].items():
                p = array[:, q]
                result = replay(p, bank['dt'], bank['seeds'][q], bank['times'], bank['policy'])
                result.pop('recordWordDifferences')
                different = p.view(np.uint32) != native.view(np.uint32)
                error = abs(result['final'][2] - ref)
                closings = [t['sample'] for t in bank['native'][q]['transitions'] if t['open'] == 0]
                readers[reader] = dict(conditionalRecorder=result,
                    pressureWordDifferencesFromInputNative=int(np.count_nonzero(different)),
                    numericPressureDifferences=int(np.count_nonzero(p != native)),
                    signBitDifferences=int(np.count_nonzero(np.signbit(p) != np.signbit(native))),
                    negativeDecisionDifferences=int(np.count_nonzero((p < 0) != (native < 0))),
                    positiveDecisionDifferences=int(np.count_nonzero((p > 0) != (native > 0))),
                    maximumAbsolutePressureDifference=float(np.max(np.abs(p.astype(float) - native.astype(float)))),
                    atInputNativeClosings=[dict(sample=i, time=bank['times'][i], nativePressure=float(native[i]), readerPressure=float(p[i])) for i in closings],
                    metalReference=ref, absoluteError=error, unchangedAllowance=.05 + .002 * abs(ref),
                    conditionalPointWithinAllowance=error <= .05 + .002 * abs(ref))
            columns.append(dict(column=column, native=bank['native'][q], readers=readers))
        rows.append(dict(id=name, inputBackend=backend, samples=len(bank['times']),
                         accumulatorPolicy=bank['policy'], columns=columns))
    pairs = []
    for bank in banks:
        if bank['backend'] != 'cuda':
            continue
        name = bank['item']['label'].rsplit('-', 1)[0]
        other = next(b for b in banks if b['item']['label'] == name + '-metal')
        for q, column in enumerate(bank['item']['columns']):
            for closing in bank['native'][q]['transitions']:
                if closing['open'] != 0:
                    continue
                i = closing['sample']
                j = int(np.argmin(np.abs(np.asarray(other['times']) - bank['times'][i])))
                pairs.append(dict(id=name, column=column, cudaSample=i, cudaTime=bank['times'][i],
                    metalSample=j, metalTime=other['times'][j], metalMinusCudaTime=other['times'][j] - bank['times'][i],
                    cudaInputs={reader: float(p[i, q]) for reader, p in bank['pressures'].items()},
                    metalInputs={reader: float(p[j, q]) for reader, p in other['pressures'].items()}))
    for path, digest in consumed.items():
        assert sha(path) == digest
    result = dict(status='complete-all-outcomes', allOwnPressureWordsExact=True, allOwnRecorderWordsExact=True,
                  nativeWordCounts=dict(metal=10488, cuda=10494), rows=rows, nearestNativeCudaClosingPairs=pairs, consumed=consumed,
                  limits='Both native reader own-input gates passed before cross-input evaluation. Conditional recorders preserve input-backend seeds, dt, all initialization samples and original verified accumulation policy. Reader differences are evaluated on identical input banks; backend banks have distinct physical time axes. No PDE evolution, continuum truth, instruction cause, new dataset pass or policy change.')
    with (ROOT / 'matrix-results.json').open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ['rows', 'consumed', 'nearestNativeCudaClosingPairs']}, indent=2))


if __name__ == '__main__':
    main()
