"""Aggregate every fixed model/outcome; overlapping strata are reported separately."""
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import sys


def aggregate(rows):
    models={}
    for name in ['written32','written64']:
        values=[r['models'][name] for r in rows if r['status']=='audited']
        models[name]=dict(cases=len(values),wholeTraceRoundedWordCompatibleCases=sum(v['wholeTraceRoundedWordCompatibility'] for v in values),
            reconstructionFallbacks=sum(v['reconstructionFallbacks'] for v in values))
        for key in ['roundedToFloat32WordDifferencesByComponent','roundedToFloat32NumericDifferencesByComponent','modelNonzeroFaceDifferenceWithEqualNativeFaces']:
            models[name][key]=[sum(v[key][i] for v in values) for i in range(3)]
        models[name]['maximumAbsoluteFluxErrorByComponent']=[max((v['maximumAbsoluteFluxErrorByComponent'][i] for v in values),default=None) for i in range(3)]
    return dict(caseGroups=len(rows),statuses=dict(Counter(r['status'] for r in rows)),executed=sum(r.get('executed',0) for r in rows),skipped=sum(r.get('skipped',0) for r in rows),models=models)


def main(root):
    root=Path(root);data=(root/'run.json').read_bytes();r=json.loads(data)
    assert r['status']=='complete-all-outcomes' and len(r['rows'])==432
    groups=defaultdict(list)
    for row in r['rows']:
        for field in ['method','policy','cfl','components','amplitudePa','nx','tiled']:
            groups[field+'='+str(row['job'][field])].append(row)
    report=dict(schema='bombcad-written-order-summary-1',inputSHA256=hashlib.sha256(data).hexdigest(),allRowsAudited=r['allRowsAudited'],
        allCommonExecutedFullTiledModelParity=all(p['eligible'] and p['sameCompleteSourceHistory'] and all(p['modelCommonExecutedFluxByteParity'].values()) for p in r['fullTiledPairs']),
        fullTiledPairs=len(r['fullTiledPairs']),all=aggregate(r['rows']),strata={k:aggregate(v) for k,v in sorted(groups.items())},
        failedOutcomes=[dict(label=x['label'],status=x['status'],error=x.get('error')) for x in r['rows'] if x['status']!='audited'],
        decision='Neither model is eligible for instruction-exact component attribution unless whole-trace word compatibility holds for every declared case. Any remaining gap stays unresolved; no production precision intervention follows from these counterfactuals.',
        limits='Component order rho,mx,E. Float64 compatibility means rounded-to-Float32 flux words only. Full/tiled observations are correlated; fixed-factor strata overlap. Equal native faces and nonzero modeled differences are conditional sample counts, not physical dissipation, global conservation, GPU intermediate observations or a peak-cause bound.')
    with (root/'summary.json').open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k!='strata'},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
