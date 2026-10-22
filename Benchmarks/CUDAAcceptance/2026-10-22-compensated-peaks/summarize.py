"""Summarize all peak decompositions without selecting a passing subset."""
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import sys


def main(raw):
    raw=Path(raw);path=raw/'results.json';data=json.loads(path.read_text());groups=defaultdict(list);columns=[]
    for row in data['rows']:
        if row['status']!='complete':continue
        job=row['job']
        for column in row['columns']:
            peak=column['atNativeMaximum'];analytic=column['analyticPeakPa']
            assert peak is not None and not column['uncoveredNativeMaximumIndices'] and column['coverageSamples']==column['totalNativeSamples']
            bound=sum(t['maximumAbsolute'] for t in column['fullCoverageTerms'][:2])
            sampling=abs(column['interpolationPeakMinusRawPeakPa'])
            gap=peak['nativePeakMinusRawFloat64PeakPa']
            lower=max(0.,abs(gap)-bound-sampling-column['maximumAbsoluteThreeTermClosureResidualPa'])
            native_times=column['native']['maximumTimesS'];ref_times=column['independentFloat64']['maximumTimesS']
            compact=dict(label=row['label'],column=column['column'],analyticPeakPa=analytic,
                nativePeakPa=column['native']['peakPa'],storedDoublePeakPa=column['storedDouble']['peakPa'],
                pairDoublePeakPa=column['pairDouble']['peakPa'],rawFloat64PeakPa=column['independentFloat64']['peakPa'],
                nativePeakMinusRawFloat64PeakPa=gap,pairPeakMinusRawFloat64PeakPa=column['pairDouble']['peakPa']-column['independentFloat64']['peakPa'],
                fullCoverageProjectionTriangleBoundPa=bound,interpolationPeakLossPa=sampling,
                descriptiveRemainingPairMismatchLowerBoundPa=lower,
                nativeMaximumTimeIntervalS=[min(native_times),max(native_times)],referenceMaximumTimeIntervalS=[min(ref_times),max(ref_times)],
                nativeMinusReferenceMaximumTimeIntervalS=[min(native_times)-max(ref_times),max(native_times)-min(ref_times)],
                atNativeMaximum=peak)
            columns.append(compact);groups[(job['method'],job['components'],job['amplitudePa'])].append(compact)
    aggregates=[]
    for (method,component,amplitude),rows in sorted(groups.items()):
        aggregates.append(dict(method=method,components=component,amplitudePa=amplitude,columns=len(rows),
            maximumAbsoluteNativePeakGapPa=max(abs(r['nativePeakMinusRawFloat64PeakPa']) for r in rows),
            maximumAbsolutePairPeakGapPa=max(abs(r['pairPeakMinusRawFloat64PeakPa']) for r in rows),
            maximumProjectionTriangleBoundPa=max(r['fullCoverageProjectionTriangleBoundPa'] for r in rows),
            columnsWithPositiveDescriptiveRemainingLowerBound=sum(r['descriptiveRemainingPairMismatchLowerBoundPa']>0 for r in rows),
            maximumDescriptiveRemainingLowerBoundPa=max(r['descriptiveRemainingPairMismatchLowerBoundPa'] for r in rows),
            atNativeMaximumTermBoundsPa=[max(r['atNativeMaximum']['terms'][i]['maximumAbsolute'] for r in rows) for i in range(4)],
            maximumInterpolationPeakLossPa=max(r['interpolationPeakLossPa'] for r in rows)))
    result=dict(schema='bombcad-saved-peak-decomposition-summary-1',sourceResultsSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
        caseGroups=data['caseGroups'],receiverHistories=data['receiverHistories'],failures=[r for r in data['rows'] if r['status']!='complete'],
        aggregates=aggregates,columns=columns,
        limits='Projection triangle bounds and remaining mismatch bounds are descriptive numerical inequalities, not acceptance thresholds or cause attribution. Time intervals compare global maximum sets and can refer to different events in multi-pulse histories; they are not universal arrival-time errors.')
    destination=raw/'summary.json'
    with destination.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['columns']},indent=2))


if __name__=='__main__':main(sys.argv[1])
