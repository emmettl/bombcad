"""Read-only acoustic matrix audit; report all outcomes without selecting a numerical gate."""
from pathlib import Path
import array, collections, hashlib, importlib.util, json, math, os, sys
repo = Path.cwd()
sys.path.insert(0, str(repo / 'Scripts/cuda'))
spec = importlib.util.spec_from_file_location('phase', repo / 'Scripts/cuda/diagnose-phase.py')
phase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phase)
root = Path(os.environ.get('BOMBCAD_DATA', '/Volumes/StudioData/bombcad')) / 'experiments/2026-10-22-weak-acoustic'
here = Path(__file__).resolve().parent
run = json.loads((root / 'run.json').read_text())
assert run['status'] == 'complete' and run['returncode'] == 0 and 'liveProcess' not in run
for name, pin in run['retainedFiles'].items():
    p = root / name
    assert p.stat().st_size == pin['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest() == pin['sha256'], name
snapshots = {r['original']: r for r in json.loads((here / 'pinned-runtime-and-sources.json').read_text())['files']}
for name, digest in run['sourceFilesSHA256'].items():
    snapshot = snapshots[name]
    assert snapshot['sha256'] == digest
    assert hashlib.sha256(Path(snapshot['snapshot']).read_bytes()).hexdigest() == digest, name


def definitions(values):
    peak = max([0.] + [v[0] for v in values])
    whole = 0.; risen = False; whole_close = None
    total = 0.; selected = 0.; phase_peak = 0.; running_peak = 0.; opened = False; stream_close = None
    for i, v in enumerate(values):
        p, dt = v[0], v[6]
        if whole_close is None:
            if p >= .5 * peak and peak > 0: risen = True
            if risen and p < 0: whole_close = i
            else: whole += max(p, 0) * dt
        total += max(p, 0) * dt
        running_peak = max(running_peak, p)
        if opened:
            if p < 0: opened = False; stream_close = i
            else: selected = total; phase_peak = max(phase_peak, p)
        if p > 0 and phase_peak < .5 * running_peak:
            selected = total; phase_peak = p; opened = True; stream_close = None
    return dict(wholeImpulse=whole, streamingDoubleImpulse=selected, wholeClosingSample=whole_close, streamingClosingSample=stream_close, semanticDifference=selected-whole)

rows = []
for amplitude in [1, 10, 100]:
    for nx in [128, 256, 512]:
        for tiled in [False, True]:
            name = f'a{amplitude}-n{nx}-' + ('tiled' if tiled else 'full')
            plain = json.loads((root / 'matrix' / (name + '-plain.json')).read_text())
            observed = json.loads((root / 'matrix' / (name + '-observed.json')).read_text())
            trace = json.loads((root / 'matrix' / (name + '-trace.json')).read_text())
            assert trace['format'] == 'bombcad-acoustic-phase-trace-1' and trace['complete']
            assert plain['stable'] and observed['stable']
            assert trace['steps'] == list(range(observed['steps'] + 1))
            assert len(trace['times']) == len(trace['values']) == len(trace['steps'])
            assert all(b > a for a,b in zip(trace['times'],trace['times'][1:]))
            assert all(len(v) == 2 and all(len(w) == 8 and all(math.isfinite(a) for a in w) for w in v) for v in trace['values'])
            assert all(v[6] == 0 for v in trace['values'][0])
            assert all(v[6] > 0 for row in trace['values'][1:] for v in row)
            meta = dict(format='bombcad-production-pressure-trace-1', columns=trace['columns'], times=trace['times'], seedRecords=trace['seedRecords'], fields=phase.FIELDS)
            replay = phase.summarize(meta, array.array('f', [v for row in trace['values'] for cell in row for v in cell]))
            parity = {key: plain[key] == observed[key] for key in ['steps','time','initialHashes','finalHashes','records','initialHostProjectedOverpressurePa']}
            for q, (column,x) in enumerate(zip(trace['columns'],trace['x'])):
                values = [row[q] for row in trace['values']]
                reference = lambda t: sum(-amplitude*math.sin(math.pi*s) if abs(s)<1 else 0 for s in [x+trace['soundSpeed']*t-8,trace['soundSpeed']*t-x-8])
                errors = [v[0] - reference(t) for v,t in zip(values,trace['times'])]
                expected_impulse = trace['analyticFirstImpulse'][q]
                expected_peak = trace['analyticPeak'][q]
                definition = definitions(values)
                initial_expected = [(-amplitude*math.sin(math.pi*s) if abs(s)<1 else 0) for s in [(i+.5)*trace['dx']-8 for i in range(nx)]]
                rows.append(dict(case=name, amplitudePa=amplitude, nx=nx, tiled=tiled, column=column, x=x, steps=observed['steps'], observationParity=parity, exactReplayPolicies=replay['columns'][q]['exactAccumulationPolicies'], analyticPeak=expected_peak, measuredPeak=values[-1][1], peakRelativeError=values[-1][1]/expected_peak-1, analyticFirstImpulse=expected_impulse, measuredStreamingImpulse=values[-1][3], streamingRelativeError=values[-1][3]/expected_impulse-1, signedPressureLinf=max(abs(e) for e in errors), initialHostProjectionLinf=max(abs(a-b) for a,b in zip(plain['initialHostProjectedOverpressurePa'],initial_expected)), negativeSamples=sum(v[0]<0 for v in values), finalOpen=values[-1][5], definition=definition, wholeRelativeError=definition['wholeImpulse']/expected_impulse-1))
assert len(rows) == 36
pairs = []
for amplitude in [1,10,100]:
    for nx in [128,256,512]:
        a=json.loads((root/'matrix'/f'a{amplitude}-n{nx}-full-plain.json').read_text())
        b=json.loads((root/'matrix'/f'a{amplitude}-n{nx}-tiled-plain.json').read_text())
        pairs.append(dict(amplitudePa=amplitude,nx=nx, sameInitialHashes=a['initialHashes']==b['initialHashes'],sameFinalHashes=a['finalHashes']==b['finalHashes'],sameStepsAndTime=[a['steps'],a['time']]==[b['steps'],b['time']],sameRecords=a['records']==b['records']))
audit_pins = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(), repo/'Scripts/cuda/diagnose-phase.py', repo/'Scripts/cuda/compare_dataset.py', repo/'Scripts/cuda/trace_columns.py']}
report=dict(auditSourceSHA256=audit_pins,status='complete', scope=__doc__, runs=36, columns=rows, tiledFullPairs=pairs, allObservationParity=all(all(r['observationParity'].values()) for r in rows), allExactReplay=all(r['exactReplayPolicies'] for r in rows), semanticMismatchColumns=sum(r['definition']['semanticDifference']!=0 or r['definition']['wholeClosingSample']!=r['definition']['streamingClosingSample'] for r in rows), allTiledFullParity=all(all(v for k,v in p.items() if k.startswith('same')) for p in pairs), rawReceipt=run, limits='Linear acoustic reference, ideal-gas core, planar rigid reflection; not finite-amplitude exact Euler, local 3-D terrain/reflection, hot-air product, CUDA validation or an admission decision.')
(here/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['columns','rawReceipt']},indent=2))
for r in rows:
    print(r['case'],r['column'],'peak%',100*r['peakRelativeError'],'I%',100*r['streamingRelativeError'],'semantic',r['definition']['semanticDifference'],'open',r['finalOpen'])
