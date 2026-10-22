"""Descriptive all-outcome summaries; no acceptance threshold or default selection."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import statistics


def main(final_path, baseline_path, output):
    final = json.loads(Path(final_path).read_text())
    baseline = json.loads(Path(baseline_path).read_text())
    ordinary = {(r['matrix'], r['amplitudePa'], r['nx'], r['tiled'], r['column']): r
                for r in baseline['columns']}
    groups = defaultdict(list)
    detailed = []
    for row in final['rows']:
        if row['status'] != 'audited':
            continue
        job = row['job']
        for column in row['columns']:
            key = (job['policy'] + '-cfl' + job['cfl'], job['amplitudePa'],
                   job['nx'], job['tiled'], column['column'])
            old = ordinary[key]
            error = column['nativeRecorderFirstImpulse'] / column['native']['analyticFirstImpulse'] - 1
            detail = dict(label=row['label'], column=column['column'],
                          eligible=row['eligibleAsCandidateObservation'],
                          nativeImpulseRelativeError=error,
                          ordinaryImpulseRelativeError=old['streamingRelativeError'],
                          absoluteErrorChange=abs(error)-abs(old['streamingRelativeError']),
                          nativePeakRelativeError=column['native']['peakRelativeError'],
                          ordinaryPeakRelativeError=old['peakRelativeError'],
                          nativeOpen=column['finalOpen'],
                          nativeOfflineClosingSample=column['native']['offline']['closingSample'],
                          nativeStreamingClosingSample=column['native']['streamingDouble']['closingSample'],
                          oracleStatus=row.get('oracleStatus'),
                          independentFloat64=column.get('independentFloat64'))
            detailed.append(detail)
            groups[(job['method'], job['components'], job['amplitudePa'])].append(detail)
    aggregates = []
    for (method, component, amplitude), rows in sorted(groups.items()):
        aggregates.append(dict(method=method, components=component, amplitudePa=amplitude,
            columns=len(rows), ineligibleColumns=sum(not r['eligible'] for r in rows),
            openColumns=sum(r['nativeOpen'] for r in rows),
            worstAbsoluteNativeImpulseRelativeError=max(abs(r['nativeImpulseRelativeError']) for r in rows),
            medianAbsoluteNativeImpulseRelativeError=statistics.median(abs(r['nativeImpulseRelativeError']) for r in rows),
            absoluteImpulseErrorImproved=sum(r['absoluteErrorChange'] < 0 for r in rows),
            absoluteImpulseErrorWorsened=sum(r['absoluteErrorChange'] > 0 for r in rows),
            absoluteImpulseErrorUnchanged=sum(r['absoluteErrorChange'] == 0 for r in rows)))
    result = dict(schema='bombcad-compensated-wave-descriptive-summary-1',
        inputSHA256={str(p): hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in [final_path, baseline_path]},
        caseStatuses=dict(Counter(r['status'] for r in final['rows'])),
        oracleStatuses=dict(Counter(r.get('oracleStatus', 'unavailable') for r in final['rows'])),
        candidateObservationFailures=[r['label'] for r in final['rows'] if not r['eligibleAsCandidateObservation']],
        tiledFullFailures=[r for r in final['tiledFullPairs'] if not r['exactFinalStateResidualRecorderClockParity']],
        aggregates=aggregates, columns=detailed,
        limits='All outcomes retained. Descriptive error comparisons against the prior ordinary method, not an admission threshold. Native impulse uses the actual recorder. Independent Float64 controls remain separate; no default selection.')
    destination=Path(output)
    with destination.open('x') as stream:
        json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in result.items() if k!='columns'},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('final');parser.add_argument('baseline');parser.add_argument('output')
    args=parser.parse_args();main(args.final,args.baseline,args.output)
