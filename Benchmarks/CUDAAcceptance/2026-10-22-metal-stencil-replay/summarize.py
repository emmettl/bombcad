"""All-outcome strict replay compatibility; no partial-case promotion."""
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import sys


def aggregate(rows):
    valid=[r for r in rows if r['status']=='audited']
    return dict(cases=len(rows),statuses=dict(Counter(r['status'] for r in rows)),audited=len(valid),
        compatibleCases=sum(r['wholeTraceByteCompatible'] for r in valid),executed=sum(r.get('executed',0) for r in rows),
        skipped=sum(r.get('skipped',0) for r in rows),
        wordDifferencesByComponent=[sum(r['wordDifferencesByComponent'][i] for r in valid) for i in range(5)],
        numericDifferencesByComponent=[sum(r['numericDifferencesByComponent'][i] for r in valid) for i in range(5)],
        maximumAbsoluteErrorByComponent=[max((r['maximumAbsoluteErrorByComponent'][i] for r in valid),default=None) for i in range(5)])


def main(root):
    root=Path(root);raw=(root/'run.json').read_bytes();run=json.loads(raw)
    assert run['status']=='complete-all-outcomes' and len(run['rows'])==432 and run['allOwnedGroupsTerminal']
    groups=defaultdict(list)
    for row in run['rows']:
        for field in ['method','policy','components','cfl','amplitudePa','nx','tiled']:
            groups[field+'='+str(row['job'][field])].append(row)
    all_=aggregate(run['rows']);pairs=run['fullTiledPairs']
    summary=dict(schema='bombcad-metal-stencil-replay-summary-1',inputSHA256=hashlib.sha256(raw).hexdigest(),
        all432ByteCompatible=run['all432ByteCompatible'],allRowsAudited=run['allRowsAudited'],all=all_,
        comparedFloat32Words=all_['executed']*10,fullTiledPairs=len(pairs),commonExecuted=sum(p.get('commonExecuted',0) for p in pairs),
        allCommonExecutedFullTiledReplayParity=all(p['eligible'] and p['commonExecutedReplayByteParity'] for p in pairs),
        analyticControls=json.loads((root/'control-results.json').read_text()),
        strata={k:aggregate(v) for k,v in sorted(groups.items())},
        failedOutcomes=[dict(label=r['label'],status=r['status'],error=r.get('error')) for r in run['rows'] if r['status']!='audited'],
        decision='Keep as a byte-compatible separate face-flux recomputation for the complete declared corpus only. Any intermediate-output variant needs its own full compatibility controls. No production-intermediate, emitted-instruction or evolved-peak-cause attribution.',
        limits='Flux component order rho,mx,my,mz,E; both faces counted. Full/tiled cases are correlated and strata overlap. This replay uses stored physical source words and lambda; it evolves no PDE and observes no production intermediates. No precision/default/admission change.')
    with (root/'summary.json').open('x') as f:json.dump(summary,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in summary.items() if k not in ['strata','analyticControls']},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
