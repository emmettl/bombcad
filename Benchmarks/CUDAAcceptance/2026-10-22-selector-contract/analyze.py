"""Compare every retained output word, with narrow timestep/stop conclusions."""
import json
import shutil

import numpy as np

from prepare import HERE, ROOT, load, save, sha


def main():
    prep = load(ROOT / 'preparation.json')
    consumed = {}

    def pin(p): consumed[str(p)] = sha(p); return p

    receipts = {stage: load(pin(ROOT / ('metal-' + stage) / 'receipt.json'))
                for stage in ['baseline', 'safe-precise']}
    baseline, candidate = receipts['baseline'], receipts['safe-precise']
    assert baseline['allBaselineWordsExact'] and baseline['nilOptions']
    assert not candidate['nilOptions']
    assert candidate['effectiveOptionsReadback']['mathMode'] == 0
    assert candidate['effectiveOptionsReadback']['mathFloatingPointFunctions'] == 1
    for key in ['binarySHA256', 'sourceSHA256', 'device']:
        assert baseline[key] == candidate[key]
    assert candidate['sourceSHA256'] == prep['sourceSHA256']
    assert candidate['binarySHA256'] == sha(ROOT / 'runtime/replay')
    compile = load(pin(ROOT / 'compile.json'))
    assert compile['linkedSDK'] == compile['linkedMinOS'] == '15.0'
    fields = prep['schemas']['metal']['controlFields']
    names = [n for n, i in sorted(fields.items(), key=lambda x: x[1])]
    names += ['speedAfter0', 'speedAfter1', 'tileCountAfter', 'dispatchAfter0', 'dispatchAfter1', 'dispatchAfter2']
    rows = []; total = 0; all_dt = all_stop = True
    banks = {}
    for row in prep['rows']:
        n = row['frames']; folder = ROOT / row['folder']; label = row['label']
        def array(p, width): return np.fromfile(pin(p), dtype='<u4').reshape(n, width)
        expected = array(folder / 'expected-metal.bin', 24)
        cuda = array(folder / 'expected-cuda.bin', 20)
        old = array(ROOT / 'metal-baseline' / label / 'outputs.bin', 24)
        new = array(ROOT / 'metal-safe-precise' / label / 'outputs.bin', 24)
        ref = np.load(pin(folder / 'source-order.npy'))
        assert np.array_equal(old, expected)
        active = np.flatnonzero(old[:, 0].view('<f4') > 0)
        dt = new[:, 0] != cuda[:, 0]
        stopped = new[:, fields['stopped']] != cuda[:, fields['stopped']]
        source_dt = new[:, 0] != ref[:, 0]
        source_stop = new[:, fields['stopped']] != ref[:, 1]
        all_dt = all_dt and not np.any(dt) and not np.any(source_dt)
        all_stop = all_stop and not np.any(stopped) and not np.any(source_stop)
        delta = new != old
        common = new[:, :20] != cuda
        total += old.size
        words = np.abs(new[:, 0].astype('int64') - cuda[:, 0].astype('int64'))
        rows.append(dict(label=label, records=n, activeSteps=len(active),
            baselineWords=int(old.size), baselineAllWordsExact=True,
            candidateVersusBaselineWordDifferences={k: int(delta[:, i].sum()) for i, k in enumerate(names)},
            candidateVersusCUDACommonWordDifferences={k: int(common[:, i].sum()) for i, k in enumerate(names[:20])},
            candidateVersusCUDADTWordDifferences=int(dt.sum()),
            candidateVersusCUDAActiveDTWordDifferences=int(dt[active].sum()),
            maximumCandidateVersusCUDADTULPs=int(words.max()),
            candidateVersusCUDAStoppedDifferences=int(stopped.sum()),
            candidateVersusSourceOrderDTWordDifferences=int(source_dt.sum()),
            candidateVersusSourceOrderStoppedDifferences=int(source_stop.sum()),
            firstCandidateVersusCUDADTDisagreements=[dict(row=int(i), candidate=int(new[i, 0]), cuda=int(cuda[i, 0]),
                sourceOrder=int(ref[i, 0])) for i in np.flatnonzero(dt)[:16]]))
        banks[label] = dict(active=active, old=old, new=new, cuda=cuda, ref=ref)
    regions = []
    for name, steps in [('made-perimeter-s1-1', [3]), ('made-perimeter-s3-1', [1]),
                        ('beirut-p0-1', [2, 3, 826, 827, 828, 899, 900, 901])]:
        for step in steps:
            bank_rows = {}
            for origin in ['metal', 'cuda']:
                bank = banks[name + '-' + origin]; i = int(bank['active'][step - 1])
                bank_rows[origin] = dict(row=i, baselineMetalDTWord=int(bank['old'][i, 0]),
                    candidateMetalDTWord=int(bank['new'][i, 0]), cudaDTWord=int(bank['cuda'][i, 0]),
                    sourceOrderDTWord=int(bank['ref'][i, 0]))
            regions.append(dict(id=name, activeStep=step, conditionalBanks=bank_rows))
    for mapping in [prep['pins'], prep['consumed'], consumed]:
        for p, h in mapping.items(): assert sha(p) == h, p
    for p in HERE.glob('*.py'):
        target = ROOT / 'analysis' / p.name
        if target.exists(): assert sha(target) == sha(p), p
        else: shutil.copyfile(p, target)
    result = dict(status='complete-all-outcomes', sourceSHA256=sha(__file__), consumed=consumed,
        baselineAllWordsExact=True, baselineWords=total, records=total // 24,
        allCandidateDTWordsMatchCUDAAndSourceOrder=bool(all_dt),
        allCandidateStoppedDecisionsMatchCUDAAndSourceOrder=bool(all_stop),
        rows=rows, conditionalRegions=regions,
        limits='Independent scalar frame replay. Native CUDA work-counter semantics differ on Metal tile banks; every common output difference retained. No evolved trajectory, instruction attribution, physical validation, throughput, production policy or admission change. Bulk held.')
    save(ROOT / 'results.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'consumed'}, indent=2))


if __name__ == '__main__': main()
