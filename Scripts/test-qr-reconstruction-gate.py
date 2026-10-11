#!/usr/bin/env python3
"""Reject coherent input, factor, reuse, frame, limiter, backoff, EOS and source corruption."""
import contextlib, copy, importlib.util, io, json, shutil, struct, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('gate',Path(__file__).with_name('verify-qr-reconstruction-output.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
root=Path(sys.argv[1]);specs=gate.expected_cases();controls=[]
def scalar(v):return {'value':str(v),'bits':struct.pack('>d',v).hex()}
def event(case,kind,which=0):return [e for e in case['events'] if e['kind']==kind][which]
def reject(name,fn):
    try:
        with contextlib.redirect_stdout(io.StringIO()):fn()
    except (ValueError,KeyError,IndexError,TypeError,OverflowError,ZeroDivisionError):return
    raise AssertionError('accepted reconstruction corruption: '+name)
for variant in ['original','shared']:
    data=json.loads((root/(variant+'.json')).read_text());cases={c['id']:c for c in data['cases']}
    def single(name,id,mutate):
        changed=copy.deepcopy(cases[id]);mutate(changed)
        def check():
            specification=specs[id];gate.verify_inputs(changed,specification)
            if changed['kind']=='gas':gate.verify_gas(changed,specification,variant,[])
            else:gate.verify_scalar(changed,specification,variant,[])
        reject(variant+'/'+name,check);controls.append(variant+'/'+name)
    # Complete-cohort checks fail before expensive numerical replay.
    changed=dict(data);changed['cases']=data['cases'][:-1]
    reject(variant+'/missing case',lambda:gate.verify_data(changed));controls.append(variant+'/missing case')
    changed=dict(data);changed['cases']=data['cases'][:-1]+[data['cases'][0]]
    reject(variant+'/duplicate case',lambda:gate.verify_data(changed));controls.append(variant+'/duplicate case')
    first='dense/0/0/0/0/false/false';bounded='dense/0/0/0/0/false/true';positive='positivity/0/true';scalarcase='scalar/0/false/false/false/0'
    single('native bits',first,lambda c:c['cell']['density'][0].__setitem__('bits','0'))
    single('case parameters',first,lambda c:c['parameters'].__setitem__('boost',99))
    single('coherent input density',first,lambda c:c['cell']['density'].__setitem__(0,scalar(3.)))
    single('volume-node geometry',first,lambda c:c['cell']['volumePoints'][0].__setitem__(0,scalar(2.)))
    single('moment matrix',first,lambda c:c['cell']['covariance'][0].__setitem__(0,scalar(.1)))
    single('ordered neighbours',first,lambda c:c['neighbours'].reverse())
    single('control/query identity',first,lambda c:c['controls'][0].__setitem__(0,scalar(2.)))
    single('actual frame velocity',first,lambda c:event(c,'frame')['velocity'].__setitem__(0,scalar(2.)))
    single('frame conserved density',first,lambda c:event(c,'frame')['densities'][0].__setitem__(0,scalar(3.)))
    single('frame mean',first,lambda c:event(c,'frame')['mean'].__setitem__(0,scalar(3.)))
    single('actual weighted basis',first,lambda c:event(c,'stencil')['rows'][0].__setitem__(0,scalar(2.)))
    single('distance multiplier',first,lambda c:event(c,'stencil')['weights'].__setitem__(0,scalar(2.)))
    single('stored factor coverage',first,lambda c:event(c,'stencil')['quadratic']['columns'].pop())
    single('stored permutation',first,lambda c:event(c,'stencil')['quadratic'].__setitem__('permutation',[0]*9))
    single('stencil reuse',first,lambda c:event(c,'solve',1).__setitem__('stencil',1))
    single('complete component RHS',first,lambda c:event(c,'solve')['rhs'].pop())
    single('RHS mean restoration',first,lambda c:event(c,'solve').__setitem__('average',scalar(3.)))
    single('coherent RHS',first,lambda c:event(c,'solve')['rhs'].__setitem__(0,scalar(2.)))
    single('constant original-data threshold',first,lambda c:event(c,'component').__setitem__('originalScale',scalar(99.)))
    single('actual degree fallback',first,lambda c:event(c,'component')['polynomial'].__setitem__('degree',0))
    single('polynomial preserved mean',first,lambda c:event(c,'component')['polynomial']['cell'].__setitem__('average',scalar(3.)))
    single('component global factor',first,lambda c:event(c,'component').__setitem__('globalFactor',scalar(.5)))
    single('component fallback flag',first,lambda c:event(c,'component').__setitem__('fallback',True))
    single('full limiter controls',bounded,lambda c:c['events'].remove(event(c,'limit')))
    single('limiter input delta',bounded,lambda c:event(c,'limit').__setitem__('delta',scalar(2.)))
    single('limiter update',bounded,lambda c:event(c,'limit').__setitem__('after',scalar(.5)))
    single('limiter result',bounded,lambda c:event(c,'limited').__setitem__('rawFactor',scalar(.5)))
    single('all control deltas',first,lambda c:event(c,'deltas')['values'].pop())
    single('density floor',first,lambda c:event(c,'floors').__setitem__('density',scalar(.1)))
    single('internal floor',first,lambda c:event(c,'floors').__setitem__('energy',scalar(.1)))
    single('complete trial theta',positive,lambda c:event(c,'probe',2).__setitem__('theta',scalar(.1)))
    single('actual EOS guard',positive,lambda c:event(c,'admissible-result').__setitem__('value',False))
    single('native internal energy',positive,lambda c:event(c,'admissible-result').__setitem__('energy',scalar(-1.)))
    single('backoff answer',positive,lambda c:event(c,'answer',2).__setitem__('value',not event(c,'answer',2)['value']))
    single('complete 48-step history',positive,lambda c:c['events'].remove(event(c,'backoff',47)))
    single('backoff interval',positive,lambda c:event(c,'backoff').__setitem__('beforeHigh',scalar(.5)))
    single('backoff midpoint',positive,lambda c:event(c,'backoff').__setitem__('mid',scalar(.1)))
    single('backoff branch update',positive,lambda c:event(c,'backoff').__setitem__('low',scalar(.1)))
    single('selected 0.99 factor',positive,lambda c:event(c,'selected').__setitem__('factor',scalar(.5)))
    single('complete final EOS inputs',first,lambda c:event(c,'outputs')['states'].pop())
    single('returned factor',first,lambda c:c['result'].__setitem__('factor',scalar(.5)))
    single('full volume mean queries',first,lambda c:c['result']['queries'].pop())
    single('lab velocity',first,lambda c:event(c,'outputs')['states'][0]['velocity'].__setitem__(0,scalar(2.)))
    single('caloric pressure',first,lambda c:event(c,'outputs')['states'][0].__setitem__('pressure',scalar(2.)))
    single('invalid-state rejection','invalid/invalid-energy',lambda c:c.__setitem__('error','invalidGeometry'))
    single('repeated scalar primary',scalarcase,lambda c:c['results'][-1].__setitem__('component',1))
    def forge_coefficients(c):
        for e in c['events']:
            if e['kind']=='solve' and e['component']==0:
                x=gate.vector(e['coefficients']);x[0]+=1;e['coefficients']=[scalar(v) for v in x]
        for result in c['results']:
            if result['component']==0:
                p=result['polynomial'];x=gate.vector(p['coefficients']);x[0]+=1;p['coefficients']=[scalar(v) for v in x]
                for query in result['queries']:query['value']=scalar(gate.evaluate(p,gate.vector(query['point']))[0])
    single('coherent coefficients and all predictions',scalarcase,forge_coefficients)
    if variant=='shared':
        single('actual relative rank floor',first,lambda c:event(c,'stencil')['quadratic'].__setitem__('tolerance',scalar(1e-8)))
        single('actual triangular condition',first,lambda c:event(c,'stencil')['quadratic'].__setitem__('condition',scalar(1.)))

with tempfile.TemporaryDirectory(prefix='qr-provenance-controls-') as scratch:
    for name,file,mutate in [
        ('source hash','source/Sources/BlastCore/FiniteVolumePressureFit.swift',lambda s:s+'\n'),
        ('compiled arithmetic','shared/source/Sources/ReconstructionCapture/ConservedGasReconstruction.swift',lambda s:s.replace('0.99 * low','0.98 * low')),
        ('dirty producer','environment.json',lambda s:s.replace('"workingTreeDirty": false','"workingTreeDirty": true')),
        ('published dependency pin','shared/Package.resolved',lambda s:s.replace('00eac5537843c85c3c25a7ecef1120f49e8aa469','0'*40)),
        ('compiled trace recipe','shared/source/Sources/ReconstructionCapture/Trace.swift',lambda s:s+'\n'),
    ]:
        target=Path(scratch)/name.replace(' ','-');target.mkdir()
        for directory in ['source','original','shared']:shutil.copytree(root/directory,target/directory)
        shutil.copyfile(root/'environment.json',target/'environment.json')
        path=target/file;before=path.read_text();after=mutate(before);assert after!=before,name;path.write_text(after)
        reject(name,lambda:gate.verify_source(target));controls.append(name)
(root/'controls.json').write_text(json.dumps({'schemaVersion':1,'rejectingControls':controls,'scope':'targeted complete-case replay for both variants plus cohort/source/version integrity; no acceptance of coherent forged coefficients'},indent=2,sort_keys=True)+'\n')
print(f'PASS {len(controls)} actual reconstruction input/reuse/frame/limiter/backoff/EOS/source corruption controls')
