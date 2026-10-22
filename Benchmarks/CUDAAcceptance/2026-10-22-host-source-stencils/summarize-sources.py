"""Aggregate every audited outcome without choosing a favorable model per scalar."""
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import sys


def aggregate(rows):
    models=defaultdict(list)
    for row in rows:
        if row['status']=='audited':
            for model in row['source']['models']:models[model['model']].append(model)
    out={}
    for name,values in sorted(models.items()):
        def summed(key):return [sum(v[key][i] for v in values) for i in range(3)]
        def maxima(key):return [max(v[key][i] for v in values) for i in range(3)]
        item=dict(cases=len(values),reconstructionFallbacks=sum(v['reconstructionFallbacks'] for v in values),
            nonzeroModelFaceDifferenceCount=summed('nonzeroModelFaceDifferenceCount'),
            equalNativeFacesForNonzeroModelDifference=summed('equalNativeFacesForNonzeroModelDifference'),
            sumAbsoluteConditionalDeltaWhereNativeFacesEqual=summed('sumAbsoluteConditionalDeltaWhereNativeFacesEqual'),
            maximumAbsoluteFluxDifferenceErrorByComponent=maxima('maximumAbsoluteFluxDifferenceErrorByComponent'),
            maximumAbsoluteConditionalDeltaErrorByComponent=maxima('maximumAbsoluteConditionalDeltaErrorByComponent'))
        if name=='separate32':
            item['wholeTraceCapturedFluxWordDifferences']=sum(v['wholeTraceCapturedFluxWordDifferences'] for v in values)
            item['casesWithWholeTraceCapturedFluxEquality']=sum(v['wholeTraceCapturedFluxWordDifferences']==0 for v in values)
        out[name]=item
    return dict(caseGroups=len(rows),statuses=dict(Counter(r['status'] for r in rows)),
        eligibleObservationGroups=sum(r['eligibleAsCandidateObservation'] for r in rows),
        executedOpportunities=sum(r['source']['executedOpportunities'] for r in rows if r['status']=='audited'),
        skippedOpportunities=sum(r['source']['skippedOpportunities'] for r in rows if r['status']=='audited'),models=out)


def main(path,output):
    path=Path(path);output=Path(output);raw=path.read_bytes();result=json.loads(raw)
    assert result['status']=='complete-all-outcome-source-audit' and len(result['rows'])==432
    rows=result['rows'];groups=defaultdict(list)
    for row in rows:
        j=row['job']
        # These are separately reported fixed-factor strata, never a pass-only subset.
        for field in ['policy','cfl','components','amplitudePa','nx','tiled','method']:
            groups[field+'='+str(j[field])].append(row)
    summary=dict(schema='bombcad-host-source-summary-1',inputSHA256=hashlib.sha256(raw).hexdigest(),
        allObservationAndPriorGates=result['allObservationAndPriorGates'],allFullTiledFinalParity=result['allFullTiledFinalParity'],
        allFullTiledSourceHistories=result['allFullTiledSourceHistories'],all=aggregate(rows),
        strata={key:aggregate(value) for key,value in sorted(groups.items())},
        failedOutcomes=[dict(label=r['label'],status=r['status'],error=r.get('error'),returncode=r.get('returncode')) for r in rows if r['status']!='audited'],
        limits='Component order rho,mx,E. Full/tiled cases are correlated. Fixed-factor strata overlap and must not be added together. Counts/sums describe observed sample opportunities and local conditional counterfactuals; they are not global conservation, physical dissipation, independent PDE trajectories, GPU intermediate observations or causal peak attribution. Every outcome retained; no model chosen per scalar.')
    with output.open('x') as stream:json.dump(summary,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in summary.items() if k!='strata'},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
