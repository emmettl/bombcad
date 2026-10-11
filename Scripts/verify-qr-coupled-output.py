#!/usr/bin/env python3
"""Replay complete selected actual gas stages against the immutable scalar SI reference."""
from fractions import Fraction as F
import argparse, hashlib, importlib.util, json, math, struct, sys
from pathlib import Path
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT/'Fixtures/EulerAdoptionBenchmark/References/verify-native-euler.py'
MANIFEST = json.loads(REFERENCE.with_name('source.json').read_text())
assert hashlib.sha256(REFERENCE.read_bytes()).hexdigest() == MANIFEST['sha256']
spec = importlib.util.spec_from_file_location('native_flux_reference', REFERENCE)
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
need = ref.require
QRROOT = ROOT/'Fixtures/QRReconstructionAdoption/References'
qr_manifest = json.loads((QRROOT/'source.json').read_text())
for name, digest in qr_manifest['sha256'].items():
    need(hashlib.sha256((QRROOT/name).read_bytes()).hexdigest() == digest, 'immutable exact QR references')
qr_spec = importlib.util.spec_from_file_location('qr_fit_reference', QRROOT/'verify-pivoted-qr-output.py')
qr = importlib.util.module_from_spec(qr_spec);qr_spec.loader.exec_module(qr)
LS_CACHE = {}

def basis(d,c):
    x,y,z=d
    return [x,y,z,(x*x+c[0][0])/2,(y*y+c[1][1])/2,(z*z+c[2][2])/2,x*y+c[0][1],x*z+c[0][2],y*z+c[1][2]]
def prediction(fit,point):
    h=fit['scale'];mean=fit['cell']['average'];centre=fit['cell']['centre']
    cov=[[-v/(h*h) if fit['volumeAware'] else 0. for v in col] for col in fit['cell']['covariance']]
    terms=basis([(a-b)/h for a,b in zip(point,centre)],cov)
    return mean+math.fsum(a*b for a,b in zip(fit['coefficients'],terms))
def volume_fits(e):
    need(set(e['fits']) == {['oneRingLinear','twoRingLinear','threeRingLinear'][e['rings']-1],'pointQuadratic','volumeQuadratic','volumeQuadraticWallBounded','volumeQuadraticBounded'}, 'complete volume pressure modes')
    findings=[]
    for kind,fits in e['fits'].items():
        if kind.startswith('volumeQuadratic') and kind != 'volumeQuadratic':continue
        for group,fit in fits.items():
            cell=e['samples'][group]; neighbours=[e['samples'][n] for n in e['stencils'][group]]
            need(fit['cell']==cell and fit['scale']==e['h'] and fit['stencilSize']==len(neighbours), 'actual full volume fit input')
            averages=[cell['average']]+[n['average'] for n in neighbours]
            need(fit['lower']==min(averages) and fit['upper']==max(averages), 'original volume fit bounds')
            h=e['h']; rows=[]; rhs=[]
            for n in neighbours:
                offset=[a-b for a,b in zip(n['centre'],cell['centre'])];weight=h/math.sqrt(math.fsum(v*v for v in offset))
                cov=[[(n['covariance'][i][j]-cell['covariance'][i][j])/(h*h) if fit['volumeAware'] else 0. for j in range(3)] for i in range(3)]
                rows.append([v*weight for v in basis([v/h for v in offset],cov)])
                rhs.append((n['average']-cell['average'])*weight)
            width=len(fit['coefficients']);need(width in [0,3,9], 'selected volume fit degree')
            if not width:continue
            rows=[r[:width] for r in rows];key=(tuple(map(tuple,rows)),tuple(rhs))
            if key not in LS_CACHE:LS_CACHE[key]=qr.exact_ls(rows,rhs)
            x,residual,norma,condition=LS_CACHE[key];error=qr.sqrt_fraction(sum((F.from_float(a)-b)**2 for a,b in zip(fit['coefficients'],x)))
            normx=qr.sqrt_fraction(sum(v*v for v in x));normr=qr.sqrt_fraction(sum(v*v for v in residual))
            bound=64*qr.EPS*max(len(rows),width)*condition*(normx+condition*normr/norma)
            need(error<=max(bound,max(8*math.ulp(float(v)) for v in x)), 'exact-native conditioning-aware volume pressure fit')
            findings.append({'mode':kind,'group':group,'width':width,'conditionFrobenius':condition,'coefficientError':error,'coefficientBound':bound})
    for kind,limits in e['bounded'].items():
        for group,limited in limits.items():
            fit=limited['fit'];need(fit==e['fits'][kind][group], 'bounded original polynomial identity')
            controls=e['wallPoints' if kind=='volumeQuadraticWallBounded' else 'allPoints'][group];factor=1.
            for point in controls:
                delta=prediction(fit,point)-fit['cell']['average']
                if delta>0:factor=min(factor,(fit['upper']-fit['cell']['average'])/delta)
                if delta<0:factor=min(factor,(fit['lower']-fit['cell']['average'])/delta)
            ref.near(limited['factor'],max(0.,min(1.,factor)),1.,'independent actual volume bound factor')
            nodes=e['volumeNodes'][group];V=math.fsum(n['weight'] for n in nodes)
            mean=math.fsum(n['weight']*(fit['cell']['average']+limited['factor']*(prediction(fit,n['point'])-fit['cell']['average'])) for n in nodes)/V
            ref.near(mean,fit['cell']['average'],max(abs(fit['lower']),abs(fit['upper'])), 'mean-preserving bounded volume polynomial')
    return findings

def decode(value):
    if isinstance(value, dict):
        if set(value) == {'value', 'bits'}:
            native = struct.unpack('>d', int(value['bits'], 16).to_bytes(8, 'big'))[0]
            text = float(value['value'])
            need(native == text or math.isnan(native) and math.isnan(text), 'native value/bits identity')
            return native
        return {k: decode(v) for k, v in value.items()}
    if isinstance(value, list):
        if value and all(isinstance(v, dict) and set(v) == {'key', 'value'} for v in value):
            pairs = [(decode(v['key']), decode(v['value'])) for v in value]
            need(len({k for k, _ in pairs}) == len(pairs), 'unique complete dictionary keys')
            return dict(pairs)
        return [decode(v) for v in value]
    return value

def native(cell):
    V, q = cell['volume'], cell['amount']
    need(len(q) == 8 and V > 0 and q[0] > 0, 'occupied complete extensive state')
    velocity = [v/q[0] for v in q[1:4]]
    pressure = (1.4-1)*(q[4] - .5*math.fsum(v*v for v in q[1:4])/q[0])/V
    values = [V, *q, *velocity, pressure]
    return {'values': values, 'bits': [struct.pack('>d', v).hex() for v in values]}

def state(cell):
    if cell['volume'] == 0:
        need(all(v == 0 for v in cell['amount']), 'zero dry-cell extensive inventory')
        return
    ref.native(native(cell), True)

def stage(event, output):
    result = output['result']; limit = event['limit']
    interval = {'time': 0., 'duration': event['duration'], 'cfl': event['cfl'],
                'limit': limit if math.isfinite(limit) else None, 'limitBits': struct.pack('>d', limit).hex(),
                'input': [native(c) for c in event['cells']],
                'faces': [{**f, 'left': native(f['leftState']) if f['leftState'] is not None else None,
                          'right': native(f['rightState']) if f['rightState'] is not None else None} for f in event['faces']],
                'walls': [{**w, 'state': native(w['state']) if w['state'] is not None else None} for w in event['walls']],
                'result': [native(c) for c in result['cells']],
                'impulses': result['wallImpulses'], 'work': result['wallWork'], 'failure': None}
    return ref.inspect_interval(interval)

def ledger(before, after, impulse, work, reservoir, label):
    for cell in before+after: state(cell)
    for k in range(8):
        a = math.fsum(c['amount'][k] for c in before); b = math.fsum(c['amount'][k] for c in after)
        load = impulse[k-1] if 1 <= k <= 3 else work if k == 4 else 0
        scale = math.fsum(abs(c['amount'][k]) for c in before+after) + abs(load) + abs(reservoir[k])
        ref.near(b-a, reservoir[k]-load, scale, label+' lane '+str(k))

def moving_composition(e, stages):
    plan=e['plan'];n=len(plan['cells']);count=2 if e['integration']=='heun' else 1
    need(len(stages)==count,'complete moving Euler/Heun stage count')
    first_input,first=stages[0];need(first_input['inventories']==plan['cells'],'actual moving first-stage inventory')
    expected=[c['amount'][:] for c in first['cells'][:n]]
    impulses=[v[:] for v in first['wallImpulses']];work=first['wallWork'][:]
    reservoir=[math.fsum(a['amount'][k]-b['amount'][k] for a,b in zip(first_input['cells'][n:],first['cells'][n:])) for k in range(8)]
    locations=[]
    for patch,boundary in enumerate(b for b in plan['boundaries'] if b['geometry']['owner']==1):
        samples=boundary['samples']
        if samples is None:locations.append((patch,boundary['geometry']['cell'],boundary['meanTime'],boundary['geometry']['centroid'],False))
        else:
            for sample in samples:locations.append((patch,boundary['geometry']['cell'],sample['time'],sample['point'],True))
    if count==2:
        second_input,second=stages[1]
        need(len(second_input['inventories'])==n,'complete moving second inventory')
        for input_cell,first_cell,V in zip(second_input['inventories'],first['cells'],plan['finalVolumes']):
            need(input_cell['amount']==first_cell['amount'] and input_cell['volume']==V,'actual corrected first stage passed to second')
        expected=[[.5*(a+b) for a,b in zip(old['amount'],new['amount'])] for old,new in zip(plan['cells'],second['cells'])]
        impulses=[[.5*(a+b) for a,b in zip(x,y)] for x,y in zip(first['wallImpulses'],second['wallImpulses'])]
        work=[.5*(a+b) for a,b in zip(first['wallWork'],second['wallWork'])]
        for slot,(_,cell,t,_,sampled) in enumerate(locations):
            if sampled:
                alpha=t/plan['duration'];new=[(1-alpha)*a+alpha*b for a,b in zip(first['wallImpulses'][slot],second['wallImpulses'][slot])]
                energy=(1-alpha)*first['wallWork'][slot]+alpha*second['wallWork'][slot]
                for k in range(3):expected[cell][k+1]-=new[k]-impulses[slot][k]
                expected[cell][4]-=energy-work[slot];impulses[slot]=new;work[slot]=energy
        second_reservoir=[math.fsum(a['amount'][k]-b['amount'][k] for a,b in zip(second_input['cells'][n:],second['cells'][n:])) for k in range(8)]
        reservoir=[.5*(a+b) for a,b in zip(reservoir,second_reservoir)]
    need(len(expected)==len(e['updated'])==n and len(locations)==len(impulses)==len(work),'complete moving composition support')
    for group,(result,amount,V) in enumerate(zip(e['updated'],expected,plan['finalVolumes'])):
        need(result['volume']==V,'actual corrected moving final volume')
        for k,(a,b) in enumerate(zip(result['amount'],amount)):ref.near(a,b,abs(b)+abs(plan['cells'][group]['amount'][k])+math.fsum(abs(c['amount'][k]) for _,r in stages for c in r['cells'][group:group+1]),'independent corrected Euler/Heun cell amount')
    for k,(a,b) in enumerate(zip(e['reservoir'],reservoir)):ref.near(a,b,math.fsum(abs(c['amount'][k]) for c in first_input['cells']), 'independent stage reservoir packet')
    patches=[[0.,0.,0.] for _ in e['wallImpulses']];powers=[0.]*len(patches);moments=[[0.,0.,0.] for _ in patches]
    for (patch,_,t,point,_),impulse,energy in zip(locations,impulses,work):
        position=[a-t*b for a,b in zip(point,plan['velocity'])];x,y,z=position;a,b,c=impulse;cross=[y*c-z*b,z*a-x*c,x*b-y*a]
        for k in range(3):patches[patch][k]+=impulse[k];moments[patch][k]+=cross[k]
        powers[patch]+=energy
    for actual,wanted in zip(e['wallImpulses'],patches):
        for a,b in zip(actual,wanted):ref.near(a,b,math.fsum(abs(v) for v in wanted),'paired temporal patch impulse')
    for actual,wanted in zip(e['wallMoments'],moments):
        for a,b in zip(actual,wanted):ref.near(a,b,math.fsum(abs(v) for v in wanted),'paired patch moment impulse')
    for a,b in zip(e['wallWork'],powers):ref.near(a,b,label='paired patch work')

def check_case(case):
    expected_parameters = ({'cellSize': .4, 'angle': float(case['id'].split('-')[1]), 'duration': 2e-7, 'velocity': [300.,100.,-40.], 'integration': case['id'].split('-')[2]} if case['id'].startswith('uniform-') else {'cellLength': .2, 'cfl': .2, 'mach': float(case['id'].split('-')[1])} if case['id'].startswith('reflection-') else {'cellSize': .2, 'angle': .23, 'rings': int(case['id'].split('-')[2])} if case['id'].startswith('initial-wall-') else {'cellSize': .2, 'angle': .23, 'cfl': .2, 'duration': .00002, 'pulseEnergy': 6400.})
    need(case['parameters'] == expected_parameters, 'complete selected case declared parameters')
    events = case['events']; stage_cells = 0; stages = 0; accepted = 0; time = 0; previous = None
    last_first = last_second = last_final = None
    fit_findings=[];moving_stages=[]
    for index, e in enumerate(events):
        kind = e['kind']
        if kind == 'volume-pressure-fits':fit_findings.extend(volume_fits(e))
        elif kind in ['moving-stage-input', 'stationary-first-input', 'stationary-second-input']:
            output_kind = kind.replace('input', 'output')
            # Retry attempts remain in the complete payload. Only returned stages have an output.
            if index+1 < len(events) and events[index+1]['kind'] == output_kind:
                if kind == 'stationary-first-input':
                    e = {**e, 'limit': maximum_step(e)}
                stage_cells += stage(e, events[index+1]); stages += 1
                if kind=='moving-stage-input':moving_stages.append((e,events[index+1]['result']))
        elif kind == 'stationary-first-output': last_first = e['result']
        elif kind == 'stationary-second-output': last_second = e['result']
        elif kind == 'stationary-final':
            need(e['first'] == last_first and e['second'] == last_second, 'actual stationary stage identity')
            need(len(e['old']) == len(e['checked']) == len(last_second['cells']), 'complete SSPRK2 cell tree')
            for old, second, final in zip(e['old'], last_second['cells'], e['checked']):
                need(final['volume'] == old['volume'], 'stationary accepted volume')
                for a, b, c in zip(old['amount'], second['amount'], final['amount']):
                    ref.near(c, .5*(a+b), abs(a)+abs(b), 'independent extensive SSPRK2 mean')
            last_final = e
        elif kind == 'reflection-step':
            need(last_final is not None and e['before'] == last_final['old'] and e['update']['cells'] == last_final['checked'], 'accepted reflection/stage linkage')
            need(e['steps'] == accepted and e['elapsed'] == time, 'complete accepted reflection clock')
            if previous is not None: need(e['before'] == previous, 'complete reflection state continuity')
            loads = [{'impulse':impulse, 'work':work} for impulse,work in zip(e['update']['wallImpulses'],e['update']['wallWork'])]
            need(len(loads) == len(last_final['boundaries']), 'complete returned stationary boundary loads')
            for i, load in enumerate(loads):
                for k in range(3): ref.near(load['impulse'][k], .5*(last_first['wallImpulses'][i][k]+last_second['wallImpulses'][i][k]), label='paired SSPRK2 impulse')
                ref.near(load['work'], .5*(last_first['wallWork'][i]+last_second['wallWork'][i]), label='paired SSPRK2 work')
            impulse = [math.fsum(w['impulse'][k] for w in loads) for k in range(3)]
            ledger(e['before'], e['update']['cells'], impulse, math.fsum(w['work'] for w in loads), [0.]*8, 'stationary accepted budget')
            shock = e['reference']; end = e['elapsed']+e['duration']
            mach=case['parameters']['mach'];rho0=1.225;p0=101325.;speed=mach*math.sqrt(1.4*p0/rho0)
            ratio=2.4*mach*mach/(.4*mach*mach+2);rho1=rho0*ratio;p1=p0*(2.8*mach*mach-.4)/2.4;u1=-speed*(1-1/ratio)
            for actual,wanted in [(shock['density'],rho0),(shock['pressure'],p0),(shock['incidentDensity'],rho1),(shock['incidentPressure'],p1),(shock['incidentVelocity'],u1),(shock['arrivalTime'],.655/speed)]:ref.near(actual,wanted,label='independent incident shock jump/arrival')
            ref.near(shock['reflectedPressure'],ref.wall_pressure(rho1,p1,-u1),label='independent reflected Hugoniot pressure')
            exact = e['area']*(shock['pressure']*e['duration']+(shock['reflectedPressure']-shock['pressure'])*(max(0,end-shock['arrivalTime'])-max(0,e['elapsed']-shock['arrivalTime'])))
            ref.near(e['exactImpulse'], exact, label='exact shock interval impulse')
            previous = e['update']['cells']; time = end; accepted += 1
        elif kind == 'moving-final':
            moving_composition(e,moving_stages);moving_stages=[]
            plan = e['plan']; updated = e['updated']; scattered = e['scattered']
            need(len(updated) == len(plan['cells']) == len(plan['members']), 'complete accepted moving group tree')
            impulse = [math.fsum(v[k] for v in e['wallImpulses']) for k in range(3)]
            ledger(plan['cells'], updated, impulse, math.fsum(e['wallWork']), e['reservoir'], 'moving group wall/reservoir budget')
            need(scattered is not None, 'actual limited scatter selected')
            cells = scattered['cells']; need(len(cells) == len(plan['memberFinalVolumes']), 'complete member scatter field')
            for c, V in zip(cells, plan['memberFinalVolumes']): need(c['volume'] == V, 'actual final member volume'); state(c)
            for group, members in enumerate(plan['members']):
                for k in range(8):
                    ref.near(math.fsum(cells[n]['amount'][k] for n in members), updated[group]['amount'][k], math.fsum(abs(cells[n]['amount'][k]) for n in members), 'independent group scatter mean')
            last_final = e
        elif kind == 'trajectory-step':
            need(last_final is not None and e['plan'] == last_final['plan'] and e['result']['cells'] == last_final['scattered']['cells'], 'actual trajectory/group/scatter linkage')
            need(e['steps'] == accepted and e['elapsed'] == time, 'complete trajectory accepted clock')
            if previous is not None: need(e['before'] == previous, 'complete trajectory state continuity')
            impulse = [math.fsum(v[k] for v in e['result']['wallImpulses']) for k in range(3)]
            ledger(e['before'], e['result']['cells'], impulse, math.fsum(e['result']['wallWork']), e['result']['reservoirExchange'], 'trajectory accepted extensive budget')
            time += e['step']; previous = e['result']['cells']; accepted += 1
    if case['id'].startswith('uniform-'):
        update = case['result']['update']; need(last_final is not None and update['cells'] == last_final['scattered']['cells'], 'uniform actual result linkage')
        for c in update['cells']:
            if c['volume'] == 0: continue
            v = ref.native(native(c), True)
            need(abs(v[1]/v[0]/1.225-1) < 1e-9 and abs(v[12]/101325-1) < 1e-9, 'comoving uniform density and pressure')
            need(max(abs(a-b) for a,b in zip(v[9:12], [300.,100.,-40.])) < 1e-7, 'comoving uniform velocity')
    elif case['id'].startswith('reflection-'):
        row = case['result'][0]; need(row['steps'] == accepted and time == row['duration'] and len(row['frames']) == 4, 'complete reflection endpoint')
    elif case['id'] == 'moving-pulse':
        row = case['result'][0]; need(row['frames'][-1]['steps'] == accepted and time == case['parameters']['duration'] and len(row['frames']) == 4, 'complete pulse endpoint')
    return {'id': case['id'], 'returnedStages': stages, 'returnedStageCells': stage_cells, 'acceptedSteps': accepted, 'volumeFitFindings': fit_findings}

def maximum_step(e):
    # Use the immutable scalar reference CFL equations via a trial interval with native output.
    rates = [0.]*len(e['cells']); volume_rates = [0.]*len(rates)
    for f in e['faces']:
        values = [ref.native(native(f['leftState'] or e['cells'][f['a']]), True), ref.native(native(f['rightState'] or e['cells'][f['b']]), True)]
        speed = max(abs(math.fsum(a*b for a,b in zip(v[9:12], f['normal'])))+math.sqrt(1.4*v[12]/(v[1]/v[0])) for v in values)
        rates[f['a']] += f['area']*speed; rates[f['b']] += f['area']*speed
    for w in e['walls']:
        v = ref.native(native(w['state'] or e['cells'][w['cell']]), True)
        un = math.fsum((a-b)*n for a,b,n in zip(v[9:12],w['velocity'],w['normal'])); rho = v[1]/v[0]; p = v[12]
        P = ref.wall_pressure(rho,p,un); wave = math.sqrt((2.4*P+.4*p)/(2*rho)) if un>0 else math.sqrt(1.4*p/rho)
        wn = math.fsum(a*b for a,b in zip(w['velocity'],w['normal']))
        rates[w['cell']] += w['area']*(abs(un)+wave+abs(wn)); volume_rates[w['cell']] += w['area']*wn
    limits = [e['cfl']*c['volume']/r for c,r in zip(e['cells'], rates) if r>0]
    limits += [e['cfl']*c['volume']/-r for c,r in zip(e['cells'],volume_rates) if r<0]
    return min(limits, default=math.inf)

def verify(report):
    d = decode(report); need(d['schemaVersion'] == 1 and len(d['cases']) == 10, 'complete selected ten-case cohort')
    expected = {'uniform-'+str(a)+'-'+i for a in [.23,.4] for i in ['euler','heun']} | {'reflection-1.2','reflection-2.0','initial-wall-1','initial-wall-2','initial-wall-3','moving-pulse'}
    need({c['id'] for c in d['cases']} == expected, 'unique complete coupled case identities')
    return {'schemaVersion': 1, 'status': 'passed', 'cases': [check_case(c) for c in d['cases']], 'scope': 'complete native selected flux, stationary composition, accepted clocks, moving/reservoir/wall and scatter ledgers; exact-native volume least-squares and sampled mean/bounds; geometry accuracy gates remain separate; no empirical blast claim'}
def iter_cases(path):
    # Complete raw cases are large; parse one case at a time without dropping any native field.
    decoder=json.JSONDecoder()
    with path.open() as stream:
        buffer=stream.read(32)
        need(buffer.startswith('{"cases":['), 'canonical complete captured report prefix')
        buffer=buffer[len('{"cases":['):]; eof=False
        while True:
            buffer=buffer.lstrip()
            if buffer.startswith(','):buffer=buffer[1:].lstrip()
            if buffer.startswith(']'):
                suffix=buffer+stream.read()
                need(json.loads('{"cases":['+suffix)=={'cases':[],'schemaVersion':1}, 'complete captured report suffix')
                return
            chunk=1024*1024
            while True:
                try:case,end=decoder.raw_decode(buffer);break
                except json.JSONDecodeError:
                    more=stream.read(chunk)
                    need(bool(more), 'complete parseable native case')
                    buffer+=more;chunk=min(chunk*2,64*1024*1024)
            yield case
            buffer=buffer[end:]
def verify_file(path):
    findings=[];ids=[]
    for case in iter_cases(path):
        case=decode(case);ids.append(case['id']);findings.append(check_case(case));print('PASS complete selected case',case['id'],flush=True)
    expected = {'uniform-'+str(a)+'-'+i for a in [.23,.4] for i in ['euler','heun']} | {'reflection-1.2','reflection-2.0','initial-wall-1','initial-wall-2','initial-wall-3','moving-pulse'}
    need(len(ids)==10 and set(ids)==expected,'complete unique ten-case history')
    return {'schemaVersion':1,'status':'passed','cases':findings,'scope':'complete native selected scalar SI flux, stationary composition, accepted clocks, moving wall/reservoir/scatter ledgers and exact-native volume least-squares/bounds; independent geometry and pressure mode aggregate gates remain separate; no empirical blast claim'}
if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('report',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    d=verify_file(a.report);a.output.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS selected actual coupled stages and independent scalar SI ledgers',sum(c['returnedStageCells'] for c in d['cases']))
