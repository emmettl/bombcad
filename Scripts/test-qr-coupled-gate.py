#!/usr/bin/env python3
"""Targeted coherent corruption controls for the actual coupled-stage replay gate."""
import argparse,copy,hashlib,importlib.util,json,shutil,sys,tempfile
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('coupled_gate',ROOT/'Scripts/verify-qr-coupled-output.py');gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
def controls(path):
    outcomes=[]
    def reject(name,case,edit,checker=gate.check_case):
        altered=copy.deepcopy(case);edit(altered)
        try:checker(altered)
        except (ValueError,KeyError,IndexError,ZeroDivisionError):outcomes.append({'id':name,'rejected':True});return
        raise ValueError('Corruption escaped '+name)
    for raw in gate.iter_cases(path):
        id=raw['id']
        if id not in ['uniform-0.23-heun','initial-wall-1']:continue
        case=gate.decode(raw)
        if id.startswith('uniform'):
            gate.check_case(case)
            def event(c,kind):return next(e for e in c['events'] if e['kind']==kind)
            reject('declared-input',case,lambda c:c['parameters'].__setitem__('duration',4e-7))
            reject('face-area',case,lambda c:event(c,'moving-stage-input')['faces'][0].__setitem__('area',.2))
            reject('prepared-trace',case,lambda c:event(c,'moving-stage-input')['faces'][0]['leftState']['amount'].__setitem__(0,1.001*event(c,'moving-stage-input')['faces'][0]['leftState']['amount'][0]))
            reject('native-stage-mass',case,lambda c:event(c,'moving-stage-output')['result']['cells'][0]['amount'].__setitem__(0,1.01*event(c,'moving-stage-output')['result']['cells'][0]['amount'][0]))
            reject('paired-wall-work',case,lambda c:event(c,'moving-stage-output')['result']['wallWork'].__setitem__(0,1.))
            reject('cfl-clock',case,lambda c:event(c,'moving-stage-input').__setitem__('limit',.5*event(c,'moving-stage-input')['limit']))
            reject('missing-second-stage',case,lambda c:c['events'].__setitem__(slice(2,4),[]))
            reject('corrected-heun-cell',case,lambda c:event(c,'moving-final')['updated'][0]['amount'].__setitem__(0,1.01*event(c,'moving-final')['updated'][0]['amount'][0]))
            reject('reservoir-packet',case,lambda c:event(c,'moving-final')['reservoir'].__setitem__(0,.01))
            reject('scatter-mean',case,lambda c:event(c,'moving-final')['scattered']['cells'][0]['amount'].__setitem__(0,.01))
            reject('paired-patch-load',case,lambda c:event(c,'moving-final')['wallImpulses'][0].__setitem__(0,.01))
        else:
            # A complete one/two-ring fit event is an independently checked unit;
            # omit unrelated geometry only from the negative-control working copy.
            e=next(e for e in case['events'] if e['kind']=='volume-pressure-fits')
            selected={k:e[k] for k in ['fits','bounded','h','rings','samples','stencils','wallPoints','allPoints','volumeNodes']}
            gate.volume_fits(selected)
            group=next(iter(selected['fits']['volumeQuadratic']))
            def coefficient(c):c['fits']['volumeQuadratic'][group]['coefficients'][0]+=1.
            reject('volume-coefficient',selected,coefficient,gate.volume_fits)
            reject('volume-average',selected,lambda c:c['samples'][group].__setitem__('average',c['samples'][group]['average']+1.),gate.volume_fits)
            reject('common-bound-factor',selected,lambda c:c['bounded']['volumeQuadraticBounded'][group].__setitem__('factor',.314),gate.volume_fits)
        del case,raw
    gate.need(len(outcomes)==14,'complete fourteen targeted coupled controls')
    return {'schemaVersion':1,'status':'passed','controls':outcomes,'scope':'targeted full-case stage/composition/clock/trace/scatter/load corruption and actual volume-fit units; full positive case tree replay is separate'}
def source_controls(output):
    spec=importlib.util.spec_from_file_location('source_gate',ROOT/'Scripts/verify-qr-coupled-source.py');source=importlib.util.module_from_spec(spec);spec.loader.exec_module(source)
    outcomes=[]
    with tempfile.TemporaryDirectory(prefix='qr-coupled-source-controls-') as scratch:
        r=Path(scratch)
        shutil.copytree(output/'source',r/'source');shutil.copyfile(output/'environment.json',r/'environment.json')
        for variant in ['original','shared']:
            shutil.copytree(output/variant/'source',r/variant/'source')
            for name in ['Package.resolved','bindings.json','linkage.txt']:shutil.copyfile(output/variant/name,r/variant/name)
        source.verify(r)
        def reject(name):
            try:source.verify(r)
            except ValueError:outcomes.append({'id':name,'rejected':True});return
            raise ValueError('Corruption escaped '+name)
        p=r/'original/Package.resolved';raw=p.read_bytes();d=json.loads(raw);d['pins'][0]['state']['revision']='0'*40;p.write_text(json.dumps(d));reject('frozen-source-pin');p.write_bytes(raw)
        p=r/'original/source/Sources/CoupledCapture/FiniteVolumePressureFit.swift';raw=p.read_bytes();b=r/'original/bindings.json';binding_raw=b.read_bytes();d=json.loads(binding_raw)
        changed=raw.replace(b'1e-10',b'2e-10');gate.need(changed!=raw,'actual protected rank cutoff corruption');p.write_bytes(changed)
        record=next(x for x in d['sources'] if x['path'].endswith('/FiniteVolumePressureFit.swift'));record['compiledSHA256']=record['sourceSHA256']=hashlib.sha256(changed).hexdigest();b.write_text(json.dumps(d));reject('coherent-original-arithmetic');p.write_bytes(raw);b.write_bytes(binding_raw)
        p=r/'original/source/Sources/CoupledCapture/MovingConnectedGasGroups.swift';raw=p.read_bytes();d=json.loads(binding_raw);changed=raw.replace(b'moving-stage-input',b'other-stage-input');gate.need(changed!=raw,'actual trace recipe corruption');p.write_bytes(changed)
        record=next(x for x in d['sources'] if x['path'].endswith('/MovingConnectedGasGroups.swift'));record['compiledSHA256']=hashlib.sha256(changed).hexdigest()
        for patch in record['patches']:patch['traced']=patch['traced'].replace('moving-stage-input','other-stage-input')
        b.write_text(json.dumps(d));reject('coherent-observation-recipe')
    return outcomes
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();d=controls(a.root/'shared.json');d['controls']+=source_controls(a.root);gate.need(len(d['controls'])==17,'complete native/source seventeen controls');(a.root/'negative-controls.json').write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS coupled corruption controls',len(d['controls']))
