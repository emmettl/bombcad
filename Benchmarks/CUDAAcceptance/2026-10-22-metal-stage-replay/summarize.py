"""Full-corpus observer compatibility result; no interpretation of rejected stages."""
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import sys


def aggregate(rows):
    valid=[r for r in rows if r['status']=='audited']
    return dict(cases=len(rows),statuses=dict(Counter(r['status'] for r in rows)),audited=len(valid),
        byteCompatibleCases=sum(r['wholeTraceFluxByteCompatible'] for r in valid),
        numericallyCompatibleCases=sum(not any(r['numericDifferencesByComponent']) for r in valid),
        executed=sum(r['executed'] for r in rows),skipped=sum(r['skipped'] for r in rows),
        allFieldsFinite=all(r.get('all91FieldsFinite',False) for r in rows),
        wordDifferencesByComponent=[sum(r['wordDifferencesByComponent'][i] for r in valid) for i in range(5)],
        numericDifferencesByComponent=[sum(r['numericDifferencesByComponent'][i] for r in valid) for i in range(5)],
        maximumAbsoluteFluxErrorByComponent=[max((r['maximumAbsoluteFluxErrorByComponent'][i] for r in valid),default=None) for i in range(5)])


def main(root):
    root=Path(root);raw=(root/'run.json').read_bytes();r=json.loads(raw)
    assert r['status']=='complete-all-outcomes' and len(r['rows'])==432 and r['allOwnedGroupsTerminal']
    groups=defaultdict(list)
    for row in r['rows']:
        for field in ['method','policy','components','cfl','amplitudePa','nx','tiled']:
            groups[field+'='+str(row['job'][field])].append(row)
    all_=aggregate(r['rows'])
    result=dict(schema='bombcad-metal-stage-replay-summary-1',inputSHA256=hashlib.sha256(raw).hexdigest(),
        all432FluxByteCompatible=r['all432FluxByteCompatible'],eligibleForSubsequentStageComparison=r['eligibleForSubsequentStageComparison'],
        fullTiledPairs=len(r['fullTiledPairs']),allCommonFullTiledPayloadParity=r['allCommonFullTiledPayloadParity'],
        comparedFluxWords=all_['executed']*10,all=all_,strata={k:aggregate(v) for k,v in sorted(groups.items())},
        failedAudits=[dict(label=x['label'],status=x['status'],error=x.get('error')) for x in r['rows'] if x['status']!='audited'],
        decision='Reject the component-output replay for component or peak-cause attribution on the complete declared corpus. Preserve every payload. The separately accepted face-only replay is unchanged; no policy/scalar subset promotion.',
        limits='Only compatibility of the ten flux words, finiteness and common-input determinism are analyzed. Rejected primitive/slope/face values are not compared with independent models. The transformation both names slope locals and adds stores; this does not isolate one source transformation or instruction as the cause. No production precision/default/admission change.')
    with (root/'summary.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in result.items() if k!='strata'},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
