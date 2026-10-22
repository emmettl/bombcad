"""Full unchanged target gates and actual native clock/closure audits; no PDE work."""
import importlib.util
import json
from pathlib import Path
import shutil
import sys

import numpy as np

from selector_runtime_prepare import ROOT, CAP, load, save, sha


def main(repo):
    repo = Path(repo); base = ROOT.parent / '2026-10-22-fixed-terrain-reference'
    consumed = {}
    def pin(p): consumed[str(p)] = sha(p); return p
    for mode in ['baseline', 'plain', 'capture']:
        r = load(pin(ROOT / ('pilots-' + mode + '.json')))
        assert r['status'] == 'complete-all-outcomes' and r['allThreeParityGatesPass'] and r['allOwnedGroupsTerminal']
        for mapping in [r['pins'], r['consumed']]:
            for p, h in mapping.items(): assert sha(pin(Path(p))) == h, p
        for row in r['rows']:
            for name, item in row['fullFiles'].items(): assert sha(pin(ROOT / mode / row['id'] / name)) == item['sha256']
    prep = load(pin(ROOT / 'runtime-preparation.json'))
    fixed = load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-fixed-terrain-reference/results.json')
    for path, h in fixed['consumedFilesSHA256'].items():
        p = Path(path.replace('$BOMBCAD_DATA', str(ROOT.parent.parent)))
        assert sha(pin(p)) == h, p
    comparison = base / 'analysis/cuda/compare_dataset.py'
    assert sha(pin(comparison)) == load(base / 'run.json')['frozenFiles']['analysis/cuda/compare_dataset.py']['sha256']
    spec = importlib.util.spec_from_file_location('original_full_gate', comparison)
    canonical = importlib.util.module_from_spec(spec); spec.loader.exec_module(canonical)
    prior = ROOT.parent / '2026-10-22-selector-contract'
    archive = load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-selector-contract/archive.json')['manifest']
    models = ROOT / 'analysis/source-order-model'; models.mkdir(exist_ok=False)
    for name in ['reference.py', 'exact_division.py']:
        p = prior / 'analysis' / name; assert sha(pin(p)) == archive['analysis/' + name]['sha256']
        shutil.copyfile(p, models / name)
    sys.path.insert(0, str(models)); from reference import evaluate
    schemas = load(CAP / 'capture-audit.json')['schemas']['metal']; cf = schemas['controlFields']; uf = schemas['uniformFields']
    rows = []
    def score(ref, cand):
        report = canonical.compare(ref, cand)
        for folder in [ref, cand]:
            for name in ['inputs.npy', 'mask.npy', 'targets.npy']: pin(folder / name)
        assert sha(ref / 'inputs.npy') == sha(cand / 'inputs.npy') and sha(ref / 'mask.npy') == sha(cand / 'mask.npy')
        target = np.load(ref / 'targets.npy').astype('float64'); candidate = np.load(cand / 'targets.npy').astype('float64')
        mask = np.load(ref / 'mask.npy') != 0
        assert target.shape == candidate.shape and target.shape[0] == 3
        assert np.isfinite(target[:, mask]).all() and np.isfinite(candidate[:, mask]).all()
        failures = []
        for channel in range(3):
            error = np.abs(target[channel] - candidate[channel]); allowed = .05 + .002 * np.abs(target[channel])
            locations = np.argwhere(mask & (error > allowed))
            assert len(locations) == report[str(channel)]['outsideTolerance']
            for y, x in locations:
                failures.append(dict(channel=channel, row=int(y), column=int(x), index=int(y * target.shape[2] + x),
                    reference=float(target[channel,y,x]), candidate=float(candidate[channel,y,x]),
                    absoluteError=float(error[y,x]), allowedError=float(allowed[y,x])))
        return dict(comparison=report, allPerValueFailures=failures,
            counts=[report[str(c)]['outsideTolerance'] for c in range(3)])
    def closure(folder, metal):
        data = np.load(pin(folder / ('pressure-trace.npy' if metal else 'trace.npy')))
        info = load(pin(folder / ('pressure-trace.json' if metal else 'trace.json')))
        result = []
        for column in range(data.shape[1]):
            transitions = np.flatnonzero((data[:-1,column,5] > 0) & (data[1:,column,5] == 0)) + 1
            i = int(transitions[0]) if len(transitions) else None
            result.append(dict(columnIndex=column, closingRow=i,
                activeStep=None if i is None else int(np.count_nonzero(data[1:i+1,column,6] > 0)),
                rawTime=None if i is None else info['times'][i],
                closingPressure=None if i is None else float(data[i,column,0]),
                finalFirstPhaseImpulse=float(data[-1,column,3])))
        return result
    for command in prep['commands']:
        name = command[command.index('--id') + 1]
        ref = base / 'cases' / name / 'metal'; cuda = base / 'recovery/current' / name / 'dataset'
        plain = ROOT / 'plain' / name; captured = ROOT / 'capture' / name
        gates = dict(baselineAgainstFixedReference=score(ref, ROOT / 'baseline' / name),
            plainCandidateAgainstFixedReference=score(ref, plain), capturedCandidateAgainstFixedReference=score(ref, captured),
            nativeCUDAAgainstFixedReference=score(ref, cuda), nativeCUDAAgainstCandidateMetal=score(plain, cuda))
        assert gates['baselineAgainstFixedReference']['comparison']['passed']
        assert gates['plainCandidateAgainstFixedReference'] == gates['capturedCandidateAgainstFixedReference']
        words = np.fromfile(pin(captured / 'clock-inputs.bin'), dtype='<u4').reshape(-1,119)
        info = load(pin(captured / 'clock-inputs.json')); assert info['complete'] and info['samples'] == len(words)
        assert np.all(words[:,117] == 0x43505245) and np.all(words[:,118] == 0x43504f53)
        control, uniforms, post = words[:,6:24], words[:,24:93], words[:,93:111]
        assert np.all(uniforms[:,uf['gaugeCount']] == 0) and np.all(uniforms[:,uf['forcedStep']] == 0)
        expected = [evaluate(control[i], uniforms[i], words[i,0], cf, uf) for i in range(len(words))]
        dt_exact = all(int(post[i,cf['dt']]) == r['dtWord'] for i,r in enumerate(expected))
        stop_exact = all(int(post[i,cf['stopped']]) == r['stopped'] for i,r in enumerate(expected))
        assert dt_exact and stop_exact
        pre_clock = control[:,cf['clockLow']].astype('uint64') | (control[:,cf['clockHigh']].astype('uint64') << np.uint64(32))
        post_clock = post[:,cf['clockLow']].astype('uint64') | (post[:,cf['clockHigh']].astype('uint64') << np.uint64(32))
        dts = post[:,cf['dt']].copy().view('<f4')
        increments = (np.maximum(dts, 0).astype('float32') * np.float32(2**40)).astype('uint64')
        assert np.array_equal(post_clock, pre_clock + increments)
        pressure = np.load(captured / 'pressure-trace.npy')
        assert np.array_equal(dts[dts>0].view('<u4'), pressure[1:,0,6].copy().view('<u4'))
        rows.append(dict(id=name,gates=gates, clock=dict(records=len(words),activeSteps=int(np.count_nonzero(dts>0)),
            allActualDTAndStoppedWordsMatchSourceOrder=True,allActualIntegerClockIncrementsExact=True),
            closures=dict(originalMetal=closure(CAP/'metal'/name,True),candidateMetal=closure(captured,True),nativeCUDA=closure(CAP/'capture'/name,False))))
    for p, h in consumed.items(): assert sha(p) == h, p
    result = dict(status='complete-all-outcomes', rows=rows, consumed=consumed, sourceSHA256=sha(__file__),
        allCandidatesPassExistingFixedReference=all(r['gates']['plainCandidateAgainstFixedReference']['comparison']['passed'] for r in rows),
        allNativeCUDAPassExistingFixedReference=all(r['gates']['nativeCUDAAgainstFixedReference']['comparison']['passed'] for r in rows),
        gate='Unchanged full valid-value 0.05+0.002*abs(reference), exact features/masks and all three channels; original fixed reference retained.',
        limits='Selector-only native trajectories with prior independent controls and complete plain/captured parity. Separate raw history times retained; no same-state claim by row or step. No production default/reference/phase/mask/tolerance/index/admission change. Bulk held.')
    save(ROOT / 'trajectory-results.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ['consumed']},indent=2))


if __name__ == '__main__': main(sys.argv[1])
