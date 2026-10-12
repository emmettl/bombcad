#!/usr/bin/env python3
"""Independent Gaussian surface integrals and complete selected pressure-load diagnostic replay."""
import argparse,copy,importlib.util,json,math,sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('coupled_native_reader',ROOT/'Scripts/verify-qr-coupled-output.py')
reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
need=reader.need;EPS=2**-52
CENTRE=[.45,1.18,1.10];WIDTH=[.14,.18,.18];CACHE={}
def dot(a,b):return math.fsum(x*y for x,y in zip(a,b))
def cross(a,b):return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def norm(a):return math.sqrt(dot(a,a))
def sub(a,b):return [x-y for x,y in zip(a,b)]
def close(a,b,scale,label,budget=512):
    need(math.isfinite(a) and math.isfinite(b) and abs(a-b)<=max(8*math.ulp(b),budget*EPS*max(abs(a),abs(b),abs(scale),1e-300)),label+': '+str(a)+' != '+str(b))
def near_vector(a,b,scale,label,budget=512):
    need(len(a)==len(b)==3,'complete '+label)
    for x,y,s in zip(a,b,scale):close(x,y,s,label,budget)
def rotation(angle):
    a=[x/math.sqrt(14) for x in [1,2,3]];c=math.cos(angle);s=math.sin(angle)
    K=[[0,-a[2],a[1]],[a[2],0,-a[0]],[-a[1],a[0],0]]
    return [[c*(i==j)+(1-c)*a[i]*a[j]+s*K[i][j] for j in range(3)] for i in range(3)]
def gaussian(point,amplitude):return amplitude*math.exp(-.5*dot([(x-y)/w for x,y,w in zip(point,CENTRE,WIDTH)],[(x-y)/w for x,y,w in zip(point,CENTRE,WIDTH)]))
def erf_difference(lo,hi):
    if lo>=0:return math.erfc(lo)-math.erfc(hi)
    if hi<=0:return math.erfc(-hi)-math.erfc(-lo)
    return math.erf(hi)-math.erf(lo)
def adaptive(f,left,right,tolerance):
    evaluations=0
    def value(x):
        nonlocal evaluations
        evaluations+=1;return f(x)
    def simpson(a,b,fa,fm,fb):return [(b-a)*(x+4*y+z)/6 for x,y,z in zip(fa,fm,fb)]
    def split(a,b,fa,fm,fb,old,tol,depth):
        m=(a+b)/2;l=value((a+m)/2);r=value((m+b)/2)
        first=simpson(a,m,fa,l,fm);second=simpson(m,b,fm,r,fb)
        difference=[x+y-z for x,y,z in zip(first,second,old)]
        if max(map(abs,difference))/15<=tol:
            return [x+y+d/15 for x,y,d in zip(first,second,difference)],[abs(d)/15 for d in difference]
        need(depth>0,'independent adaptive surface integral converged')
        x,ex=split(a,m,fa,l,fm,first,tol/2,depth-1);y,ey=split(m,b,fm,r,fb,second,tol/2,depth-1)
        return [a+b for a,b in zip(x,y)],[a+b for a,b in zip(ex,ey)]
    fa=value(left);fm=value((left+right)/2);fb=value(right)
    answer,error=split(left,right,fa,fm,fb,simpson(left,right,fa,fm,fb),tolerance,24)
    return answer,error,evaluations

def surface_unit(angle,tolerance):
    R=rotation(angle);position=[1.013,1.027,1.041];sides=[.8]*3;faces=[]
    for axis in range(3):
        a=[R[i][(axis+1)%3] for i in range(3)];b=[R[i][(axis+2)%3] for i in range(3)]
        for sign in [-1,1]:
            n=[sign*R[i][axis] for i in range(3)];base=[.4*v for v in n]
            q=[(p+r-c)/w for p,r,c,w in zip(position,base,CENTRE,WIDTH)]
            av=[v/w for v,w in zip(a,WIDTH)];bv=[v/w for v,w in zip(b,WIDTH)];A=dot(bv,bv)
            def line(u):
                shifted=[v+u*w for v,w in zip(q,av)];B=dot(bv,shifted);C=dot(shifted,shifted)
                lo=-.4;hi=.4;root=math.sqrt(A/2);prefactor=math.exp(-.5*(C-B*B/A))
                integral=prefactor*math.sqrt(math.pi/(2*A))*erf_difference(root*(lo+B/A),root*(hi+B/A))
                atlo=math.exp(-.5*(A*lo*lo+2*B*lo+C));athi=math.exp(-.5*(A*hi*hi+2*B*hi+C))
                moment=(atlo-athi)/A-B/A*integral
                return [integral,u*integral,moment]
            integrals,error,count=adaptive(line,-.4,.4,tolerance)
            normal_moments=[cross(v,n) for v in [base,a,b]]
            force=[-v*integrals[0] for v in n]
            torque=[-math.fsum(normal_moments[j][i]*integrals[j] for j in range(3)) for i in range(3)]
            faces.append({'axis':axis,'sign':sign,'integrals':integrals,'estimatedErrors':error,'evaluations':count,'force':force,'torque':torque})
    return {'faces':faces,'force':[math.fsum(f['force'][i] for f in faces) for i in range(3)],'torque':[math.fsum(f['torque'][i] for f in faces) for i in range(3)]}
def surface_reference(row):
    angle=row['rotation']
    if angle not in CACHE:
        coarse=surface_unit(angle,1e-12);fine=surface_unit(angle,2.5e-13)
        scale=math.fsum(f['integrals'][0] for f in fine['faces'])
        need(max(abs(a-b) for name in ['force','torque'] for a,b in zip(coarse[name],fine[name]))<1e-10*scale,'independent surface tolerance refinement')
        CACHE[angle]=fine
    result=CACHE[angle];amplitude=row['pulseAmplitude'];scale=amplitude*math.fsum(f['integrals'][0] for f in result['faces'])
    for name in ['force','torque']:
        expected=[amplitude*v for v in result[name]]
        # The production 32-point tensor rule and independent adaptive rule have
        # distinct truncation errors. This declared selected-case bound is retained.
        need(norm(sub(row['reference'+name.title()],expected))<=1e-10*scale,'independent Gaussian whole-face '+name)
    return result

def prepared_traces(event):
    prepared=event['prepared'];locations=event['locations'];walls=prepared['walls']
    need(len(walls)==len(locations),'complete prepared wall trace tree')
    result=[]
    for loc,wall in zip(locations,walls):
        b=loc['boundary'];g=b['geometry'];cell=wall['cell']
        result.append({'cell':cell,'point':g['centroid'],'time':b['meanTime'],'normal':wall['normal'],'area':wall['area'],'velocity':wall['velocity'],
                       'state':wall['state'] or event['inventories'][cell],
                       'pressureReconstruction':prepared['pressureDiagnostics'][cell] if prepared['pressureDiagnostics'] is not None else None})
    return result

def aggregate(traces,values,row,reference,diagnostic=None,bounds=None):
    need(len(traces)==len(values)>0,'complete load evaluation tree');amplitude=row['pulseAmplitude'];position=row['bodyCentre'];velocity=row['velocity']
    area=math.fsum(t['area'] for t in traces);forces=[];torques=[];errors=[];scales=[];negative=outside=0.;nonpositive=0
    minimum=min(101325+v for v in values);maximum=max(101325+v for v in values)
    for index,(t,value) in enumerate(zip(traces,values)):
        point=[p-t['time']*u for p,u in zip(t['point'],velocity)];exact=gaussian(point,amplitude)
        applied=[t['area']*value*n for n in t['normal']];forces.append(applied);torques.append(cross(sub(point,position),applied))
        errors.append(t['area']*abs(value-exact));scales.append(t['area']*exact)
        if 101325+value<=0:nonpositive+=1
        if value < -1e-5:negative+=t['area']
        if bounds is not None:
            low,high,tolerance=bounds[index]
            if value<low-tolerance or value>high+tolerance:outside+=t['area']
    force=[math.fsum(f[i] for f in forces) for i in range(3)];torque=[math.fsum(f[i] for f in torques) for i in range(3)]
    # Include primitive pressure cancellation and signed force/torque cancellation
    # in the rounding scales; net load alone is not a valid scale.
    cancellation=math.fsum(t['area']*(101325+abs(v)+abs(t['state']['amount'][4]/t['state']['volume'])) for t,v in zip(traces,values))
    fscale=[math.fsum(abs(f[i]) for f in forces)+cancellation for i in range(3)]
    tscale=[math.fsum(abs(f[i]) for f in torques)+cancellation for i in range(3)]
    near_vector(reference['force'],force,fscale,'complete reported force')
    near_vector(reference['torque'],torque,tscale,'complete reported torque')
    close(reference['power'],dot(velocity,force),dot([abs(v) for v in velocity],fscale),'complete paired pressure power')
    close(reference['relativeForceError'],norm(sub(force,row['referenceForce']))/norm(row['referenceForce']),norm(fscale)/norm(row['referenceForce']),'reported relative force error')
    close(reference['relativeTorqueError'],norm(sub(torque,row['referenceTorque']))/norm(row['referenceTorque']),norm(tscale)/norm(row['referenceTorque']),'reported relative torque error')
    close(reference['relativePressureL1'],math.fsum(errors)/math.fsum(scales),cancellation/math.fsum(scales),'reported pressure L1')
    if diagnostic is not None:
        close(diagnostic['minimumPressure'],minimum,101325+max(map(abs,values)),'reported pressure minimum')
        close(diagnostic['maximumPressure'],maximum,101325+max(map(abs,values)),'reported pressure maximum')
        need(diagnostic['nonpositivePressureSamples']==nonpositive,'reported nonpositive pressure sample count')
        close(diagnostic['negativeExcessAreaFraction'],negative/area,1.,'reported negative area fraction')
        close(diagnostic['outsideStencilAreaFraction'],outside/area,1.,'reported outside-stencil area fraction')
    return {'force':force,'torque':torque,'power':dot(velocity,force),'pressureL1':math.fsum(errors)/math.fsum(scales),'roundingForceScales':fscale,'roundingTorqueScales':tscale,'samples':len(traces)}

def volume_modes(event,reported,row):
    modes={m['kind']:m for m in reported['modes']};need(set(modes)==set(event['fits']) and len(modes)==5,'complete five volume pressure modes')
    traces=event['traces'];area=math.fsum(t['area'] for t in traces);findings=[]
    for kind,mode in modes.items():
        values=[];bounds=[]
        for t in traces:
            fit=event['fits'][kind][t['cell']];value=reader.prediction(fit,t['point'])
            if kind in event['bounded']:
                limited=event['bounded'][kind][t['cell']];value=fit['cell']['average']+limited['factor']*(value-fit['cell']['average'])
            values.append(value);bounds.append((fit['lower'],fit['upper'],1e-5))
        findings.append({'kind':kind,**aggregate(traces,values,row,mode['loads'],mode,bounds)})
    for field,kind,degree in [('quadraticFallbackAreaFraction','volumeQuadratic',9),('pointQuadraticFallbackAreaFraction','pointQuadratic',9),('linearFallbackAreaFraction',['oneRingLinear','twoRingLinear','threeRingLinear'][event['rings']-1],3)]:
        expected=math.fsum(t['area'] for t in traces if len(event['fits'][kind][t['cell']]['coefficients'])<degree)/area
        close(reported[field],expected,1.,'reported degree/fallback area')
    mean=math.fsum(t['area']*event['fits']['volumeQuadratic'][t['cell']]['stencilSize'] for t in traces)/area
    close(reported['meanStencilSize'],mean,mean,'reported connected stencil size')
    need(reported['stencilRings']==event['rings'] and 0<=reported['maximumMomentResidual']<1e-8,'declared bounded moment residual/rings')
    diagnostics={b['kind']:b for b in reported['bounds']};need(set(diagnostics)==set(event['bounded']),'complete volume bound diagnostic tree')
    for kind,limited in event['bounded'].items():
        d=diagnostics[kind];average_residual=bound_violation=0.
        for group,bounded in limited.items():
            fit=bounded['fit'];mean=fit['cell']['average'];factor=bounded['factor'];nodes=event['volumeNodes'][group]
            def value(p):return mean+factor*(reader.prediction(fit,p)-mean)
            recovered=math.fsum(n['weight']*value(n['point']) for n in nodes)/math.fsum(n['weight'] for n in nodes)
            average_residual=max(average_residual,abs(recovered-mean)/max(1.,abs(mean)))
            for p in event['wallPoints' if kind=='volumeQuadraticWallBounded' else 'allPoints'][group]:
                v=value(p);bound_violation=max(bound_violation,max(0,fit['lower']-v,v-fit['upper'])/max(1,abs(fit['lower']),abs(fit['upper'])))
        close(d['meanFactor'],math.fsum(t['area']*limited[t['cell']]['factor'] for t in traces)/area,1.,'reported volume common-factor mean')
        close(d['activeAreaFraction'],math.fsum(t['area'] for t in traces if limited[t['cell']]['factor']<1-1e-12)/area,1.,'reported limiter active area')
        close(d['maximumRelativeAverageResidual'],average_residual,1.,'reported sampled mean residual')
        close(d['maximumRelativeBoundViolation'],bound_violation,1.,'reported sampled bound residual')
    return findings

def diagnostics(events,row,reported):
    constant,limited,centroid=[prepared_traces(e) for e in events];traces=limited
    centres=events[1]['plan']['oldCentres'];pointvalues=[gaussian(p,row['pulseAmplitude']) for p in centres]
    gradients=[[-(p[i]-CENTRE[i])/(WIDTH[i]**2)*value for i in range(3)] for p,value in zip(centres,pointvalues)]
    kinds=['supplied','constant','leastSquares','limited','centroidConstant','centroidLeastSquares','centroidLimited','analyticTaylor','averageAnalyticGradient']
    modes={m['kind']:m for m in reported['modes']};need(len(reported['modes'])==9 and set(modes)==set(kinds),'complete nine decomposition modes')
    findings=[]
    for kind in kinds:
        values=[];bounds=[]
        for n,t in enumerate(traces):
            cell=t['cell'];fit=t['pressureReconstruction'];pf=centroid[n]['pressureReconstruction'];offset=sub(t['point'],centres[cell])
            if kind=='supplied':value=gaussian([p-t['time']*u for p,u in zip(t['point'],row['velocity'])],row['pulseAmplitude'])
            elif kind=='constant':value=fit['value']-101325
            elif kind=='leastSquares':value=fit['value']-101325+dot(fit['gradient'],offset)
            elif kind=='limited':value=reader.ref.native(reader.native(t['state']),True)[12]-101325
            elif kind=='centroidConstant':value=pointvalues[cell]
            elif kind=='centroidLeastSquares':value=pf['value']-101325+dot(pf['gradient'],offset)
            elif kind=='centroidLimited':value=reader.ref.native(reader.native(centroid[n]['state']),True)[12]-101325
            elif kind=='analyticTaylor':value=pointvalues[cell]+dot(gradients[cell],offset)
            else:value=fit['value']-101325+dot(gradients[cell],offset)
            values.append(value);b=pf if kind.startswith('centroid') or kind=='analyticTaylor' else fit
            bounds.append((b['lower']-101325,b['upper']-101325,1e-10*max(abs(b['lower']),abs(b['upper']),1.)))
        mode=modes[kind];findings.append({'kind':kind,**aggregate(traces,values,row,mode['loads'],mode,bounds)})
    area=math.fsum(t['area'] for t in traces)
    values={'meanPressureLimiterFactor':math.fsum(t['area']*t['pressureReconstruction']['factor'] for t in traces)/area,
            'centroidDataLimiterFactor':math.fsum(t['area']*t['pressureReconstruction']['factor'] for t in centroid)/area,
            'limiterActiveAreaFraction':math.fsum(t['area'] for t in traces if t['pressureReconstruction']['factor']<1-1e-12)/area,
            'rankDeficientAreaFraction':math.fsum(t['area'] for t in traces if t['pressureReconstruction']['rankDeficient'])/area}
    for name,value in values.items():close(reported[name],value,1.,'reported pressure-decomposition '+name)
    return findings

def check_case(case):
    row=case['result'][0];need(row['pulseCentre']==CENTRE and row['pulseWidth']==WIDTH and row['boxSize']==[.8]*3 and row['bodyCentre']==[1.013,1.027,1.041] and row['velocity']==[300.,100.,-40.] and row['targetPulseEnergy']==6400 and row['cellSize']==.2 and row['rotation']==.23,'complete declared Gaussian/cube input')
    need(row['pulseAmplitude']>0 and row['duration']==row['cellSize']*1e-9 and row['referenceOrderDifference']<1e-8,'declared instantaneous-limit policy')
    reference=surface_reference(row);prep=[e for e in case['events'] if e['kind']=='initial-wall-prepared'];volumes=[e for e in case['events'] if e['kind']=='volume-pressure-fits']
    need(len(prep)==6 and len(volumes)==2,'complete full/half-duration diagnostic history')
    outputs=[]
    for half in [False,True]:
        index=int(half);p=prep[3*index:3*index+3];v=volumes[index];duration=row['duration']/(2 if half else 1)
        need(all(e['plan']['duration']==duration for e in p) and v['plan']['duration']==duration,'actual full/half physical clocks')
        constant,limited,_=[prepared_traces(e) for e in p];need(v['traces']==limited,'actual volume/pressure trace linkage')
        prefix='halfDuration' if half else '';field=lambda name:prefix+name[0].upper()+name[1:] if half else name
        for name,traces,known in [('supplied',constant,True),('constant',constant,False),('limited',limited,False)]:
            values=[]
            for t in traces:
                if known:values.append(gaussian([x-t['time']*u for x,u in zip(t['point'],row['velocity'])],row['pulseAmplitude']))
                else:
                    state=reader.ref.native(reader.native(t['state']),True);normal=dot(sub(state[9:12],t['velocity']),t['normal'])
                    values.append(reader.ref.wall_pressure(state[1]/state[0],state[12],normal)-101325)
            outputs.append({'halfDuration':half,'kind':name,**aggregate(traces,values,row,row[field(name)])})
        outputs.extend({'halfDuration':half,**r} for r in diagnostics(p,row,row[field('decomposition')]))
        outputs.extend({'halfDuration':half,**r} for r in volume_modes(v,row[field('volumeFits')],row))
    need(len(outputs)==34,'complete thirty-four pressure load modes per ring case')
    return {'id':case['id'],'surfaceReference':reference,'modes':outputs}
def verify(path):
    results=[];controls=[]
    for raw in reader.iter_cases(path):
        if not raw['id'].startswith('initial-wall-'):continue
        case=reader.decode(raw);results.append(check_case(case));print('PASS complete pressure load/diagnostic case',case['id'],flush=True)
        if case['id']=='initial-wall-1':
            for label in ['reference-force','reported-force','paired-power','mode-tree','limiter-area','bound-residual']:
                altered={**case,'result':copy.deepcopy(case['result'])};row=altered['result'][0]
                if label=='reference-force':row['referenceForce'][0]+=10.
                elif label=='reported-force':row['volumeFits']['modes'][0]['loads']['force'][0]+=1.
                elif label=='paired-power':row['decomposition']['modes'][0]['loads']['power']+=1.
                elif label=='mode-tree':row['halfDurationVolumeFits']['modes'].pop()
                elif label=='limiter-area':row['volumeFits']['bounds'][0]['activeAreaFraction']=.314
                else:row['volumeFits']['bounds'][0]['maximumRelativeAverageResidual']=.001
                try:check_case(altered)
                except ValueError:controls.append({'id':label,'rejected':True});continue
                raise ValueError('Pressure corruption escaped '+label)
    need(len(results)==3 and {r['id'] for r in results}=={'initial-wall-1','initial-wall-2','initial-wall-3'} and len(controls)==6,'complete three-ring reference/control tree')
    return {'schemaVersion':1,'status':'passed','cases':results,'controls':controls,'scope':'complete selected full/half pressure mode/load/limiter output replay and independent Gaussian face integrals; existing moment residual bound retained; no evolved Euler pressure accuracy or empirical claim'}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('report',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();d=verify(a.report);a.output.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
