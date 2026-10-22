"""Reproduce the remaining native scalar-input partition from immutable completed histories."""
import sys
from pathlib import Path

import numpy as np

from selector_runtime_prepare import ROOT, CAP, load, save, sha


def main(repo):
    repo = Path(repo)
    sys.path.insert(0, str(ROOT / 'analysis/source-order-model-qualified'))
    from reference import evaluate
    schema = load(CAP / 'capture-audit.json')['schemas']['metal']; cf = schema['controlFields']; uf = schema['uniformFields']
    archive = load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-clock-inputs/archive.json')['manifest']
    rows = []; consumed = {}
    for name in ['made-perimeter-s1-1', 'made-perimeter-s3-1', 'beirut-p0-1']:
        banks = {}
        for origin, p in [('metal', ROOT / 'capture' / name / 'clock-inputs.bin'), ('cuda', CAP / 'capture' / name / 'clock-inputs.bin')]:
            if origin == 'cuda': assert sha(p) == archive[str(p.relative_to(CAP))]['sha256']
            consumed[str(p)] = sha(p)
            w = np.fromfile(p, dtype='<u4').reshape(-1,119); post = w[:,93:111]
            active = np.flatnonzero(post[:,cf['dt']].copy().view('<f4') > 0)
            banks[origin] = w, post, active
        m, mp, ma = banks['metal']; c, cp, ca = banks['cuda']; assert len(ma) == len(ca)
        different = np.flatnonzero(mp[ma,cf['dt']] != cp[ca,cf['dt']]); j = int(different[0]); mi, ci = int(ma[j]), int(ca[j])
        models = []
        for w, post, i in [(m,mp,mi), (c,cp,ci)]:
            expected = evaluate(w[i,6:24], w[i,24:93], w[i,0], cf, uf)
            assert int(post[i,cf['dt']]) == expected['dtWord']; models.append(expected)
        rows.append(dict(id=name,activeSteps=len(ma),differentNativeDTWords=len(different),firstDifferentActiveStep=j+1,
            firstRows=[mi,ci],fastestWords=[int(m[mi,0]),int(c[ci,0])],dtWords=[int(mp[mi,cf['dt']]),int(cp[ci,cf['dt']])],
            uniformDifferences={k:[int(m[mi,24+uf[k]]),int(c[ci,24+uf[k]])] for k in ['cfl','dx','maxStep','forcedStep']
                                if m[mi,24+uf[k]] != c[ci,24+uf[k]]},
            bothDTEqualUnclippedProposal=all(x['dtWord'] == x['proposalWord'] for x in models),
            pairedFastestDifferences=int(np.count_nonzero(m[ma,0] != c[ca,0]))))
    prior = load(ROOT / 'remaining-native-clock.json'); assert rows == prior['rows'] and consumed == prior['consumed']
    report = dict(prior, sourceSHA256=sha(__file__), recomputationExact=True)
    save(ROOT / 'remaining-native-clock-verified.json', report)
    print('Remaining native clock partition recomputes exactly: first divergences4/2/3, differing speed words, same unclipped expression')


if __name__ == '__main__': main(sys.argv[1])
