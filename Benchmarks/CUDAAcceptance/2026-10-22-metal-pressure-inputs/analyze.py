"""All declared conditional pressure models on both captured backend states."""
import ctypes
import ctypes.util
import hashlib
import json
from pathlib import Path
import struct
import sys

import numpy as np
from pressure_model import f32, overpressure

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-metal-pressure-inputs')
CUDA = ROOT.parent / '2026-10-22-phase-pressure-inputs'
BASE = ROOT.parent / '2026-10-22-fixed-terrain-reference'
lib = ctypes.CDLL(ctypes.util.find_library('m'))
fma = lib.fmaf
fma.argtypes = [ctypes.c_float] * 3
fma.restype = ctypes.c_float


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def word(x):
    return struct.unpack('<I', struct.pack('<f', float(x)))[0]


def replay(pressures, dt, seed, times, policy, expected=None):
    x, y, z, peak, going = map(f32, seed)
    differences = 0
    transitions = []
    last = going
    for i, (p, d) in enumerate(zip(pressures, dt)):
        p, d = f32(float(p)), f32(max(float(d), 0.))
        y = fma(max(p, 0.), d, y) if policy == 'fused' else f32(y + f32(max(p, 0.) * d))
        x = max(x, p)
        if going:
            if p < 0:
                going = 0.
            else:
                z, peak = y, max(peak, p)
        if p > 0 and peak < .5 * x:
            z, peak, going = y, p, 1.
        current = [x, y, z, peak, going]
        if expected is not None:
            differences += sum(word(a) != word(b) for a, b in zip(current, expected[i]))
        if going != last:
            transitions.append(dict(sample=i, time=times[i], open=going, pressure=p, firstPhaseImpulse=z))
            last = going
    return dict(final=[x, y, z, peak, going], recordWordDifferences=differences, transitions=transitions)


def main():
    capture = load(ROOT / 'run.json')
    prior = load(CUDA / 'analysis-results.json')
    assert capture['status'] == 'complete-all-outcomes' and capture['allThreeCaptureGatesPass']
    assert prior['allThreeInputAndNativeReplayGatesPass']
    assert sha(Path(__file__).with_name('pressure_model.py')) == prior['modelSHA256']
    consumed = {}
    for path, digest in capture['pins'].items():
        assert sha(path) == digest, path
        consumed[path] = digest
    for path, digest in prior['consumed'].items():
        assert sha(path) == digest, path
        consumed[path] = digest

    def read(path):
        consumed[str(path)] = sha(path)
        return np.load(path, allow_pickle=False)

    for path in [ROOT / 'run.json', CUDA / 'analysis-results.json', Path(__file__),
                 Path(__file__).with_name('pressure_model.py'), Path(sys.executable).resolve(),
                 Path(np._core._multiarray_umath.__file__)]:
        consumed[str(path)] = sha(path)
    staged = []
    # Gate every native trace before evaluating any conditional model.
    for case in capture['rows']:
        name, columns = case['id'], case['columns']
        old = next(r for r in prior['rows'] if r['id'] == name)
        assert [c['column'] for c in old['nativeColumns']] == columns
        proof_path = CUDA / 'cases' / name / 'parity-and-endpoints.json'
        consumed[str(proof_path)] = sha(proof_path)
        assert load(proof_path)['uniforms'] == case['uniforms']
        reference = read(BASE / 'cases' / name / 'metal/targets.npy')
        backends = {}
        for backend in ['metal', 'cuda']:
            folder = ROOT / 'cases' / name / 'inputs' if backend == 'metal' else CUDA / 'cases' / name
            inputs = read(folder / 'pressure-inputs.npy')
            trace = read(folder / ('pressure-trace.npy' if backend == 'metal' else 'trace.npy'))
            metadata_path = folder / ('pressure-trace.json' if backend == 'metal' else 'trace.json')
            consumed[str(metadata_path)] = sha(metadata_path)
            meta = load(metadata_path)
            assert meta['columns'] == columns
            assert inputs.shape == (len(meta['times']), len(columns), 16)
            assert trace.shape == (len(meta['times']), len(columns), 8)
            assert inputs.dtype == trace.dtype == np.dtype('<f4')
            assert np.isfinite(inputs).all() and np.isfinite(trace).all()
            seeds = meta['seedRecords'] if backend == 'metal' else [c['seed'] for c in old['nativeColumns']]
            policy = 'fused' if backend == 'metal' else 'separate'
            native = []
            for q, column in enumerate(columns):
                result = replay(trace[:, q, 0], trace[:, q, 6], seeds[q], meta['times'], policy, trace[:, q, 1:6])
                assert result['recordWordDifferences'] == 0, (name, backend, column, 'native word replay')
                target = float(reference[2].flat[column]) if backend == 'metal' else old['nativeColumns'][q]['cudaFirstPhase']
                assert word(result['final'][2]) == word(target), 'Native target mismatch'
                native.append(result)
            backends[backend] = dict(inputs=inputs, trace=trace, meta=meta, seeds=seeds, policy=policy, native=native)
        assert np.array_equal(backends['metal']['inputs'][0, :, :6].view(np.uint32),
                              backends['cuda']['inputs'][0, :, :6].view(np.uint32))
        staged.append((case, reference, backends))

    rows = []
    for case, reference, backends in staged:
        outputs = {}
        for backend, data in backends.items():
            arrays = {}
            models = []
            for method in ['source64', 'root64']:
                for weights in ['native', 'column64']:
                    key = method + '-' + weights
                    p = np.empty(data['inputs'].shape[:2], dtype=np.float64)
                    for i in range(len(p)):
                        for q in range(p.shape[1]):
                            p[i, q] = overpressure(data['inputs'][i, q], case['uniforms'], method, weights)
                    assert np.isfinite(p).all()
                    arrays[key] = p
                    results = []
                    for q, column in enumerate(case['columns']):
                        conditional = replay(p[:, q], data['trace'][:, q, 6], data['seeds'][q], data['meta']['times'], data['policy'])
                        ref = float(reference[2].flat[column])
                        error = abs(conditional['final'][2] - ref)
                        allowance = .05 + .002 * abs(ref)
                        results.append(dict(column=column, conditionalRecorder=conditional,
                                            metalReference=ref, absoluteError=error, allowance=allowance,
                                            conditionalPointWithinAllowance=error <= allowance,
                                            initialPressure=float(p[0, q])))
                    models.append(dict(model=key, columns=results))
            path = ROOT / 'cases' / case['id'] / (backend + '-conditional-pressures.npz')
            assert not path.exists()
            np.savez_compressed(path, **arrays)
            data['modelArrays'] = arrays
            outputs[backend] = dict(accumulationPolicy=data['policy'], native=data['native'], models=models,
                                    samples=len(data['meta']['times']), initialTime=data['meta']['times'][0])
        pairs = []
        for backend, data in backends.items():
            other_name = 'cuda' if backend == 'metal' else 'metal'
            other = backends[other_name]
            other_times = np.asarray(other['meta']['times'], dtype=np.float64)
            for q, column in enumerate(case['columns']):
                for transition in data['native'][q]['transitions']:
                    if transition['open'] != 0:
                        continue
                    i, time = transition['sample'], transition['time']
                    j = int(np.argmin(np.abs(other_times - time)))
                    a, b = data['inputs'][i, q], other['inputs'][j, q]
                    pairs.append(dict(ownBackend=backend, otherBackend=other_name, column=column,
                                      ownSample=i, ownTime=time, otherSample=j, otherTime=float(other_times[j]),
                                      otherMinusOwnTime=float(other_times[j] - time),
                                      ownNativePressure=float(data['trace'][i, q, 0]),
                                      otherNativePressure=float(other['trace'][j, q, 0]),
                                      cellWordDifferences=int(np.count_nonzero(a[6:].view(np.uint32) != b[6:].view(np.uint32))),
                                      ownCells=a[6:].astype(float).tolist(), otherCells=b[6:].astype(float).tolist(),
                                      models={key: dict(own=float(values[i, q]), other=float(other['modelArrays'][key][j, q]))
                                              for key, values in data['modelArrays'].items()}))
        rows.append(dict(id=case['id'], columns=case['columns'], backends=outputs, nearestClosingPairs=pairs))
    for path, digest in consumed.items():
        assert sha(path) == digest, 'Consumed file changed: ' + path
    result = dict(status='complete-all-outcomes', allNativeWordReplayGatesPass=True, rows=rows, consumed=consumed,
                  limits='All four declared Double models retained; source Float32 constants promoted to Double. Conditional recorders use native verified backend accumulation policy and all samples including initialization. Nearest-time states are not simultaneous states or continuum truth. No tolerance, mask, phase, default or admission change.')
    with (ROOT / 'comparison-results.json').open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ['rows', 'consumed']}, indent=2))


if __name__ == '__main__':
    main()
