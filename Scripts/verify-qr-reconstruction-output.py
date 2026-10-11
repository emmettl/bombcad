#!/usr/bin/env python3
"""Independent native geometry, least-squares and complete reconstruction policy replay."""
import argparse, collections, hashlib, importlib.util, json, math, subprocess, sys, tempfile
from fractions import Fraction as F
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('qr_reference',ROOT/'Fixtures/QRReconstructionAdoption/References/verify-pivoted-qr-output.py')
qr=importlib.util.module_from_spec(spec);spec.loader.exec_module(qr)
EPS=2**-52
scalar,vector,matrix=qr.scalar,qr.vector,qr.matrix
def need(ok,label):
    if not ok:raise ValueError(label)
def same(a,b,label='native identity'):
    need(len(a)==len(b),label+' dimensions')
    for x,y in zip(a,b):need(x==y or math.isnan(x) and math.isnan(y),label)
def close(a,b,scale=None,budget=128,label='independent rounding reference'):
    if math.isnan(a) or math.isnan(b):need(math.isnan(a) and math.isnan(b),label);return
    if math.isinf(a) or math.isinf(b):need(a==b,label);return
    need(abs(a-b)<=max(4*math.ulp(b),budget*EPS*max(abs(b),abs(scale or 0),1e-300)),f'{label}: {a} != {b}')
def seqsum(values):
    total=0.
    for value in values:total+=value
    return total
def divide(a,b):
    if b==0:return math.nan if a==0 else math.copysign(math.inf,a*math.copysign(1,b))
    return a/b
def expected_nodes(centre,index):
    axis=[v/math.sqrt(14) for v in [1,2,3]];angle=.04*index;c=math.cos(angle);s=math.sin(angle);extent=[.1+.003*index,.15,.08+.002*index];result=[]
    for n in range(8):
        v=[extent[j]*(-1 if n&(1<<j)==0 else 1)/math.sqrt(3) for j in range(3)];cross=[axis[1]*v[2]-axis[2]*v[1],axis[2]*v[0]-axis[0]*v[2],axis[0]*v[1]-axis[1]*v[0]];dot=sum(x*y for x,y in zip(axis,v))
        result.append([centre[j]+v[j]*c+cross[j]*s+axis[j]*dot*(1-c) for j in range(3)])
    return result
def lab_density(point,family,boost):
    x,y,z=map(F.from_float,point)
    if family in ['pressure','constant']:
        pressure=F(101325) if family=='constant' else F(101325)+2500*x+900*y*y
        u=[F.from_float(1.225),F(0),F(0),F(0),pressure/F.from_float(1.4-1),F(0),F(0),F(0)]
    else:
        q=lambda v:F.from_float(v)
        u=[2+q(.1)*x+q(.02)*x*x-q(.01)*y*z,q(.3)+q(.12)*y+q(.02)*x*z,-q(.2)+q(.15)*z-q(.01)*y*y,q(.05)+q(.1)*x-q(.02)*x*y,3+q(.2)*y+q(.04)*z*z+q(.02)*x*y,F(0),F(0),F(0)]
    b=list(map(F.from_float,boost));momentum=u[1:4];out=u[:]
    for j in range(3):out[j+1]+=u[0]*b[j]
    out[4]+=sum(v*w for v,w in zip(b,momentum))+u[0]*sum(v*v for v in b)/2
    return out
AXES=[[1.,0.,0.],[0.,1.,0.],[0.,0.,1.],[-1.,0.,0.],[0.,-1.,0.],[0.,0.,-1.]]
BOOSTS=[[0.,0.,0.],[300.,-200.,70.]]
def expected_cases():
    cases={}
    for fi,family in enumerate(['polynomial','pressure']):
        for origin in [0,1]:
            shift=[0.,0.,0.] if origin==0 else [17.,-8.,31.]
            samples=[([shift[0]+x,shift[1]+y,shift[2]+z],i) for i,(z,y,x) in enumerate((z,y,x) for z in [-1,0,1] for y in [-1,0,1] for x in [-1,0,1])]
            for bi in [0,1]:
                for si,h in enumerate([.1,.4,2.]):
                    for rev in [False,True]:
                        for bound in [False,True]:
                            indices=[i for i in range(27) if i!=13]
                            if rev:indices.reverse()
                            id=f'dense/{fi}/{origin}/{bi}/{si}/{str(rev).lower()}/{str(bound).lower()}'
                            cases[id]={'kind':'gas','parameters':{'family':family,'origin':origin,'boost':bi,'scaleIndex':si,'reverse':rev},'cell':samples[13],'neighbours':[samples[i] for i in indices],'family':family,'boost':BOOSTS[bi],'scale':h,'bound':bound,'offsets':[[.2,-.1,.17],[-.3,.4,-.2]]}
    for family in ['axes','planar','single','empty']:
        points=AXES if family=='axes' else [p for p in AXES if p[2]==0] if family=='planar' else AXES[:1] if family=='single' else []
        for bi in [0,1]:
            for bound in [False,True]:cases[f'sparse/{family}/{bi}/{str(bound).lower()}']={'kind':'gas','parameters':{'family':family,'boost':bi},'cell':([0.,0.,0.],0),'neighbours':[(p,i+1) for i,p in enumerate(points)],'family':'polynomial','boost':BOOSTS[bi],'scale':1.,'bound':bound,'offsets':[[.2,-.1,.17]]}
    for bi in [0,1]:
        for bound in [False,True]:cases[f'positivity/{bi}/{str(bound).lower()}']={'kind':'gas','parameters':{'family':'positivity','boost':bi},'cell':([0.,0.,0.],0),'neighbours':[(p,i+1) for i,p in enumerate(AXES)],'family':'positivity','boost':BOOSTS[bi],'scale':1.,'bound':bound,'offsets':[[1.,1.,0.]]}
    for di,d in enumerate([1e-4,1e-8,1e-10,1e-12]):
        points=[[math.cos(2*math.pi*i/12),math.sin(2*math.pi*i/12),d*math.sin(3*(2*math.pi*i/12))] for i in range(12)]
        for bound in [False,True]:cases[f'ring/{di}/{str(bound).lower()}']={'kind':'gas','parameters':{'family':'ring','deltaIndex':di},'cell':([0.,0.,0.],0),'neighbours':[(p,i+1) for i,p in enumerate(points)],'family':'polynomial','boost':BOOSTS[0],'scale':.4,'bound':bound,'offsets':[[.2,-.1,.17]]}
    for si,h in enumerate([1e-200,1e-100,1e100,1e200]):
        for bound in [False,True]:cases[f'extreme/{si}/{str(bound).lower()}']={'kind':'gas','parameters':{'family':'extreme','scaleIndex':si},'cell':([0.,0.,0.],0),'neighbours':[(p,i+1) for i,p in enumerate(AXES)],'family':'polynomial','boost':BOOSTS[0],'scale':h,'bound':bound,'offsets':[[.2,-.1,.17]]}
    for bi in [0,1]:
        for family in ['constant','far-bound']:cases[f'{family}/{bi}']={'kind':'gas','parameters':{'family':family,'boost':bi},'cell':([0.,0.,0.],0),'neighbours':[(p,i+1) for i,p in enumerate(AXES)],'family':'constant' if family=='constant' else 'polynomial','boost':BOOSTS[bi],'scale':1.,'bound':True,'offsets':[] if family=='constant' else [[3.,2.,-1.],[-3.,-2.,1.]]}
    for failure in ['empty-controls','nan-control','duplicate-centre','invalid-density','invalid-energy','zero-scale','nan-geometry']:
        cases['invalid/'+failure]={'kind':'gas','parameters':{'family':'invalid','failure':failure},'cell':([0.,0.,0.],0),'neighbours':[((AXES[0] if failure!='duplicate-centre' else [0.,0.,0.]),1 if failure!='duplicate-centre' else 0)],'family':'polynomial','boost':BOOSTS[0],'scale':0. if failure=='zero-scale' else 1.,'bound':True,'offsets':[],'failure':failure}
    for origin in [0,1]:
        shift=[0.,0.,0.] if origin==0 else [17.,-8.,31.]
        for aware in [False,True]:
            for quadratic in [False,True]:
                for rev in [False,True]:
                    neighbours=[([shift[j]+p[j] for j in range(3)],i+1) for i,p in enumerate(AXES)]
                    if rev:neighbours.reverse()
                    for si,h in enumerate([.1,.4,2.]):cases[f'scalar/{origin}/{str(aware).lower()}/{str(quadratic).lower()}/{str(rev).lower()}/{si}']={'kind':'scalar','parameters':{'origin':origin,'aware':aware,'quadratic':quadratic,'reverse':rev,'scaleIndex':si},'cell':(shift,0),'neighbours':neighbours,'family':'polynomial','boost':BOOSTS[0],'scale':h,'aware':aware,'quadratic':quadratic,'offsets':[[.2,-.1,.17]]}
    need(len(cases)==191,'declared 191-case input tree');return cases
def verify_sample(record,spec,family,boost,failure=None,is_cell=False):
    centre,index=spec;actual=vector(record['centre']);wanted=centre[:]
    if failure=='nan-geometry' and is_cell:wanted[0]=math.nan
    for a,b in zip(actual,wanted):close(a,b,abs(b),256,label='independent centre input')
    points=[vector(p) for p in record['volumePoints']]
    if family=='positivity':
        expected=[[(1 if n&(1<<j) else -1)/math.sqrt(3) for j in range(3)] for n in range(8)] if is_cell else [centre]
        base=[1.,0.,0.,0.,1.,0.,0.,0.] if is_cell else [1.,1.3*centre[0],1.3*centre[1],0.,1.,0.,0.,0.]
        rho=F.from_float(base[0]);b=list(map(F.from_float,boost));density=list(map(F.from_float,base));momentum=density[1:4]
        for j in range(3):density[j+1]+=rho*b[j]
        density[4]+=sum(v*w for v,w in zip(b,momentum))+rho*sum(v*v for v in b)/2
        expected_cov=[[1/3 if i==j and is_cell else 0. for j in range(3)] for i in range(3)]
    else:
        expected=expected_nodes(centre,index)
        density=[sum(lab_density(p,family,boost)[j] for p in points)/len(points) for j in range(8)]
        expected_cov=[[float(sum((F.from_float(p[i])-F.from_float(centre[i]))*(F.from_float(p[j])-F.from_float(centre[j])) for p in points)/len(points)) for j in range(3)] for i in range(3)]
    need(len(points)==len(expected),'complete native volume points')
    for p,q in zip(points,expected):
        for a,b in zip(p,q):close(a,b,max(1,abs(b)),256,'independent rotated volume node')
    cov=matrix(record['covariance']);need(len(cov)==3 and all(len(c)==3 for c in cov),'native moment matrix dimensions')
    for i in range(3):
        for j in range(3):close(cov[i][j],expected_cov[i][j],math.sqrt(abs(expected_cov[i][i]*expected_cov[j][j])),256,'independent native volume moments')
    if failure=='invalid-density' and is_cell:density[0]=F(-1)
    if failure=='invalid-energy' and is_cell:density[4]=F(-1)
    for a,b in zip(vector(record['density']),density):close(a,float(b),max(1,abs(float(b))),256,'independent polynomial volume-average/boost input')
def verify_inputs(case,spec):
    need(case['kind']==spec['kind'] and case['parameters']==spec['parameters'],'case kind/parameters')
    need(scalar(case['scale'])==spec['scale'],'source scale parameter')
    if case['kind']=='gas':need(case['bound']==spec['bound'],'bound-components parameter')
    verify_sample(case['cell'],spec['cell'],spec['family'],spec['boost'],spec.get('failure'),True)
    need(len(case['neighbours'])==len(spec['neighbours']),'complete ordered neighbours')
    for s,p in zip(case['neighbours'],spec['neighbours']):verify_sample(s,p,spec['family'],spec['boost'])
    volume=[vector(p) for p in case['cell']['volumePoints']];centre=vector(case['cell']['centre']);wanted=volume+[[spec['cell'][0][j]+p[j] for j in range(3)] for p in spec['offsets']]
    if spec.get('failure')=='empty-controls':wanted=[]
    if spec.get('failure')=='nan-control':wanted[0]=[math.nan,0.,0.]
    actual=[vector(p) for p in case['controls' if case['kind']=='gas' else 'queries']]
    need(len(actual)==len(wanted),'full control/query input tree')
    for a,b in zip(actual,wanted):same(a,b,'control/query identity')
def basis(point,centre,covariance,scale,aware):
    d=[(p-c)/scale for p,c in zip(point,centre)]
    multiplier=divide(-1.,scale*scale) if aware else 0.
    c=[[multiplier*v for v in values] for values in covariance] if aware else [[0.]*3 for _ in range(3)]
    return d+[(d[0]*d[0]+c[0][0])/2,(d[1]*d[1]+c[1][1])/2,(d[2]*d[2]+c[2][2])/2,d[0]*d[1]+c[0][1],d[0]*d[2]+c[0][2],d[1]*d[2]+c[1][2]]
def evaluate(poly,point):
    terms=basis(point,vector(poly['cell']['centre']),matrix(poly['cell']['covariance']),scalar(poly['scale']),poly['aware']);coeff=vector(poly['coefficients']);mean=scalar(poly['cell']['average'])
    value=mean+seqsum(c*t for c,t in zip(coeff,terms));magnitude=abs(mean)+seqsum(abs(c*t) for c,t in zip(coeff,terms))
    return value,magnitude
def frame_transform(u,velocity):
    values=list(map(F.from_float,u));v=list(map(F.from_float,velocity));out=values[:]
    for j in range(3):out[j+1]-=values[0]*v[j]
    out[4]-=sum(v[j]*values[j+1] for j in range(3))-values[0]*sum(x*x for x in v)/2
    scales=[abs(float(x)) for x in values]
    for j in range(3):scales[j+1]+=abs(float(values[0]*v[j]))
    scales[4]+=sum(abs(float(v[j]*values[j+1])) for j in range(3))+abs(float(values[0]*sum(x*x for x in v)/2))
    return [float(x) for x in out],scales

class Cursor:
    def __init__(self,events):self.events=events;self.index=0
    def next_kind(self):return self.events[self.index]['kind'] if self.index<len(self.events) else None
    def pop(self,kind,component=None):
        need(self.index<len(self.events),'missing '+kind+' event');event=self.events[self.index];self.index+=1
        need(event['kind']==kind,'event order '+kind+' versus '+event['kind'])
        if component is not None:need(event['component']==component,'actual component event binding')
        return event
    def finished(self):need(self.index==len(self.events),'unverified extra source events')
def scalar_sample_same(record,centre,cov,mean):
    same(vector(record['centre']),centre,'polynomial centre')
    actual=matrix(record['covariance']);need(actual==cov,'polynomial volume moments')
    need(scalar(record['average'])==mean,'actual restored mean')
PIVOT_DIAGNOSTICS={}
def pivot_diagnostics(a):
    key=tuple(map(tuple,a))
    if key in PIVOT_DIAGNOSTICS:return PIVOT_DIAGNOSTICS[key]
    n=len(a[0]);cols=[[F.from_float(row[j]) for row in a] for j in range(n)];g=[[sum(x*y for x,y in zip(c,d)) for d in cols] for c in cols]
    initial=max(g[j][j] for j in range(n));trace=sum(g[j][j] for j in range(n));ratios=[]
    if not initial:return [],0.
    for k in range(n):
        p=max(range(k,n),key=lambda j:g[j][j]);g[k],g[p]=g[p],g[k]
        for row in g:row[k],row[p]=row[p],row[k]
        pivot=g[k][k]
        if pivot<=0:ratios.append(0.);break
        ratios.append(qr.sqrt_fraction(pivot/initial))
        for i in range(k+1,n):
            for j in range(k+1,n):g[i][j]-=g[i][k]*g[k][j]/pivot
    # Selected-cohort absolute pivot-norm roundoff envelope. This records an
    # ambiguous exact-versus-floating cutoff comparison, not a different floor.
    envelope=64*EPS*max(len(a),n)*qr.sqrt_fraction(trace/initial)
    PIVOT_DIAGNOSTICS[key]=(ratios,envelope);return ratios,envelope
def verify_stencil(event,case,aware,expected_mean,variant,findings):
    centre=vector(case['cell']['centre']);cov=matrix(case['cell']['covariance']);h=scalar(case['scale'])
    scalar_sample_same(event['cell'],centre,cov,expected_mean)
    need(scalar(event['scale'])==h and event['aware']==aware and event['stencil']==0,'actual stencil geometry/identity')
    samples=case['neighbours'];need(len(event['neighbours'])==len(samples),'full scalar neighbour binding')
    actual=matrix(event['rows']);weights=vector(event['weights']);need(len(actual)==len(weights)==len(samples),'full weighted stencil rows')
    for index,sample in enumerate(samples):
        p=vector(sample['centre']);nc=matrix(sample['covariance']);delta=[p[j]-centre[j] for j in range(3)];distance=math.sqrt(seqsum(v*v for v in delta));weight=h/distance
        close(weights[index],weight,abs(weight),128,'independent distance multiplier')
        d=[v/h for v in delta];multiplier=divide(1.,h*h) if aware else 0.;difference=[[nc[i][j]-cov[i][j] for j in range(3)] for i in range(3)];c=[[multiplier*v for v in row] for row in difference] if aware else [[0.]*3 for _ in range(3)]
        terms=d+[(d[0]*d[0]+c[0][0])/2,(d[1]*d[1]+c[1][1])/2,(d[2]*d[2]+c[2][2])/2,d[0]*d[1]+c[0][1],d[0]*d[2]+c[0][2],d[1]*d[2]+c[1][2]]
        need(len(actual[index])==9,'complete nine-column basis')
        for value,term in zip(actual[index],terms):close(value,term*weight,abs(term*weight),512,'independent actual weighted volume-aware basis')
    for key,width in [('quadratic',9),('linear',3)]:
        factor=event[key];a=[row[:width] for row in actual]
        expected_error=qr.expected_factor_error(a,1e-10)
        boundary=False
        if expected_error in [None,'rankDeficient'] and len(a)>=width:
            ratios,envelope=pivot_diagnostics(a);boundary=any(abs(ratio-1e-10)<=envelope for ratio in ratios)
            if boundary:findings.append({'id':case['id']+'/'+key,'kind':'rank-boundary','exactPivotRatios':ratios,'roundoffEnvelope':envelope,'actualAccepted':factor is not None,'exactPolicyError':expected_error})
        if variant=='shared':need((factor is None)==bool(expected_error) or boundary,'shared explicit factor availability '+case['id']+'/'+key)
        if factor is None:continue
        q=matrix(factor['columns']);r=matrix(factor['upper']);perm=factor['permutation'];exponent=factor['scaleExponent']
        need(len(q)==width and all(len(col)==len(a) for col in q) and len(r)==width and all(len(row)==width for row in r),'complete actual stored factors')
        need(sorted(perm)==list(range(width)) and all(math.isfinite(v) for col in q+r for v in col),'finite factors/permutation')
        scaled=[[math.ldexp(v,-exponent) for v in row] for row in a];scale=max(abs(v) for row in scaled for v in row)
        orth=max(abs(seqsum(x*y for x,y in zip(q[i],q[j]))-float(i==j)) for i in range(width) for j in range(width))
        reconstruction=max(abs(seqsum(q[k][i]*r[k][j] for k in range(width))-scaled[i][perm[j]])/scale for i in range(len(a)) for j in range(width))
        bound=256*EPS*max(len(a),width)
        if variant=='shared':
            need(scalar(factor['tolerance'])==1e-10,'actual relative rank floor');need(orth<=bound and reconstruction<=bound,'actual shared factor quality')
            norm=qr.normalized([v for row in a for v in row]);need(norm is not None and norm[1]==exponent,'actual matrix scaling')
            condition=scalar(factor['condition']);reference=qr.upper_condition(r);close(condition,reference,reference,1024*width,'actual triangular condition diagnostic')
        findings.append({'id':case['id']+'/'+key,'kind':'factor','orthogonality':orth,'reconstruction':reconstruction,'diagnosticExceeded':orth>2e-10 or reconstruction>2e-10})
    return event
def verify_solve(event,stencil,mean,nearby,quadratic,variant,caseid,findings):
    need(event['stencil']==stencil['stencil'] and scalar(event['average'])==mean and event['quadratic']==quadratic,'actual shared stencil solve identity/mean')
    same(vector(event['neighbours']),nearby,'actual complete neighbour RHS data');weights=vector(stencil['weights']);rhs=vector(event['rhs']);need(len(rhs)==len(nearby),'complete RHS dimensions')
    for value,average,weight in zip(rhs,nearby,weights):close(value,(average-mean)*weight,abs(value),16,'actual weighted mean-difference RHS')
    width=9 if quadratic and stencil['quadratic'] is not None else 3 if stencil['linear'] is not None else 0
    coeff=vector(event['coefficients']);need(len(coeff)==width,'actual quadratic/linear/constant fallback')
    if width:
        if variant=='original':
            # Source conformance to the observed immutable original factors is
            # distinct from their independent exact least-squares accuracy.
            factor=stencil['quadratic' if width==9 else 'linear'];q=matrix(factor['columns']);r=matrix(factor['upper']);projected=[seqsum(v*w for v,w in zip(col,rhs)) for col in q];x=[0.]*width
            for i in reversed(range(width)):x[i]=(projected[i]-seqsum(r[i][j]*x[j] for j in range(i+1,width)))/r[i][i]
            ordered=[0.]*width
            for j,p in enumerate(factor['permutation']):ordered[p]=x[j]
            for value,wanted in zip(coeff,ordered):close(value,wanted,abs(wanted),32,'original source solve over actual stored factors')
        a=[row[:width] for row in matrix(stencil['rows'])];na=qr.normalized([v for row in a for v in row]);nb=qr.normalized(rhs);need(na is not None and nb is not None,'supported solve normalization')
        an=[na[0][i*width:(i+1)*width] for i in range(len(a))];bn,be=nb;ae=na[1];reference,residual,norm_a,condition=qr.exact_ls(an,bn)
        beta=[F.from_float(v)*F(2)**(ae-be) for v in coeff];norm_x=qr.sqrt_fraction(sum(v*v for v in reference));norm_r=qr.sqrt_fraction(sum(v*v for v in residual));error=qr.sqrt_fraction(sum((v-w)**2 for v,w in zip(beta,reference)))
        bound=64*EPS*max(len(a),width)*condition*(norm_x+condition*norm_r/norm_a);floor=max(8*math.ulp(float(x)) for x in reference)
        if variant=='shared':need(error<=max(bound,floor),'independent conditioning-aware actual solve '+caseid)
        findings.append({'id':caseid,'kind':'solve','conditionFrobenius':condition,'normalizedCoefficientError':error,'normalizedCoefficientBound':bound,'originalDiagnosticExceeded':error>2e-10*max(1,norm_x)})
    return coeff
def verify_poly(poly,case,mean,lower,upper,coeff,aware):
    scalar_sample_same(poly['cell'],vector(case['cell']['centre']),matrix(case['cell']['covariance']),mean)
    same(vector(poly['coefficients']),coeff,'actual polynomial coefficients');need(poly['degree']==(2 if len(coeff)==9 else 1 if len(coeff)==3 else 0),'actual polynomial degree')
    need(scalar(poly['scale'])==scalar(case['scale']) and scalar(poly['lower'])==lower and scalar(poly['upper'])==upper and poly['aware']==aware and poly['stencilSize']==len(case['neighbours']),'actual polynomial construction/policy')
def admissible(cursor,wanted,density_floor,internal_floor):
    entry=cursor.pop('admissible-input');u=vector(entry['density']);need(len(u)==8,'complete EOS input')
    for value,expected in zip(u,wanted):close(value,expected,max(1,abs(expected)),16,'actual trial conserved density')
    need(scalar(entry['densityFloor'])==density_floor and scalar(entry['internalFloor'])==internal_floor,'actual sampled EOS floors')
    outcome=cursor.pop('admissible-result')
    if not all(math.isfinite(v) for v in u) or u[0]<=density_floor:
        need(outcome['value'] is False and outcome['energy'] is None,'actual finite/density guard');return False
    exact=F.from_float(u[4])-sum(F.from_float(v)**2 for v in u[1:4])/(2*F.from_float(u[0]));energy=scalar(outcome['energy']);scale=abs(u[4])+abs(float(exact-F.from_float(u[4])))
    close(energy,float(exact),scale,32,'independent internal-energy reference')
    expected=math.isfinite(energy) and energy>internal_floor;need(outcome['value']==expected,'native rounded EOS predicate');return expected
def probe(cursor,theta,mean,deltas,density_floor,internal_floor):
    need(scalar(cursor.pop('probe')['theta'])==theta,'actual backoff trial theta')
    answer=True
    for delta in deltas:
        wanted=[m+theta*d for m,d in zip(mean,delta)]
        if not admissible(cursor,wanted,density_floor,internal_floor):answer=False;break
    need(cursor.pop('answer')['value']==answer,'actual short-circuit EOS result');return answer
def query_expected(polys,factor,velocity,point):
    values=[];magnitudes=[]
    for poly in polys:
        value,scale=evaluate(poly,point);mean=scalar(poly['cell']['average']);values.append(mean+factor*(value-mean));magnitudes.append(abs(mean)+abs(factor)*(scale+abs(mean)))
    frame=values+[0.,0.,0.];lab,scales=frame_transform(frame,[-v for v in velocity])
    return lab,[max(s,magnitudes[i] if i<5 else 0.) for i,s in enumerate(scales)]
def verify_query(query,polys,factor,velocity,point):
    same(vector(query['point']),point,'complete output point identity');need(scalar(query['volume'])==1,'actual unit-density trace volume')
    expected,scales=query_expected(polys,factor,velocity,point);u=vector(query['amount']);need(len(u)==8,'complete output conserved state')
    for value,wanted,scale in zip(u,expected,scales):close(value,wanted,scale,512,'independent mean/limited/inverse-frame output')
    rho=u[0];need(rho>0 and all(math.isfinite(v) for v in u),'finite positive sampled lab density')
    for value,momentum in zip(vector(query['velocity']),u[1:4]):close(value,momentum/rho,abs(momentum/rho),32,'independent lab velocity')
    internal=F.from_float(u[4])-sum(F.from_float(v)**2 for v in u[1:4])/(2*F.from_float(rho));pressure=float(F.from_float(1.4-1)*internal)
    close(scalar(query['pressure']),pressure,(abs(u[4])+abs(float(internal-F.from_float(u[4]))))*(1.4-1),64,'independent caloric EOS')
    need(scalar(query['pressure'])>0,'sampled final lab EOS');return u

def verify_scalar(case,spec,variant,findings):
    cursor=Cursor(case['events']);densities=[vector(s['density']) for s in [case['cell']]+case['neighbours']]
    stencil=verify_stencil(cursor.pop('stencil',-1),case,spec['aware'],densities[0][0],variant,findings)
    for record,sample,density in zip(stencil['neighbours'],case['neighbours'],densities[1:]):scalar_sample_same(record,vector(sample['centre']),matrix(sample['covariance']),density[0])
    queries=[vector(p) for p in case['queries']];need(len(case['results'])==6,'complete five RHS and repeated primary results')
    for result,c in zip(case['results'],[0,1,2,3,4,0]):
        need(result['component']==c,'actual distinct scalar RHS order');mean=densities[0][c];nearby=[d[c] for d in densities[1:]]
        coefficients=verify_solve(cursor.pop('solve',c),stencil,mean,nearby,spec['quadratic'],variant,case['id']+'/'+str(c),findings)
        poly=result['polynomial'];verify_poly(poly,case,mean,min([mean]+nearby),max([mean]+nearby),coefficients,spec['aware'])
        need(len(result['queries'])==len(queries),'full scalar prediction tree')
        for actual,point in zip(result['queries'],queries):
            same(vector(actual['point']),point,'scalar output query identity');value,scale=evaluate(poly,point);close(scalar(actual['value']),value,scale,64,'independent polynomial/restored mean evaluation')
        if spec['aware']:
            volume=result['queries'][:8];recovered=seqsum(scalar(q['value'])/8 for q in volume);scale=max([abs(mean)]+[abs(scalar(q['value'])) for q in volume]);close(recovered,mean,scale,512,'independent scalar volume mean')
    need(case['results'][0]==case['results'][-1],'same stored factor exactly repeats primary RHS')
    cursor.finished()

def verify_gas(case,spec,variant,findings):
    cursor=Cursor(case['events']);failure=spec.get('failure')
    if failure:
        expected='invalidState' if failure in ['invalid-density','invalid-energy'] else 'invalidGeometry'
        need(case.get('error')==expected and 'result' not in case,'declared invalid input rejection');cursor.finished();return
    need('error' not in case,'unexpected valid reconstruction rejection '+case['id'])
    samples=[case['cell']]+case['neighbours'];lab=[vector(s['density']) for s in samples]
    frame_event=cursor.pop('frame',-1);velocity=vector(frame_event['velocity']);need(len(velocity)==3,'velocity frame dimensions')
    for value,momentum in zip(velocity,lab[0][1:4]):close(value,momentum/lab[0][0],abs(momentum/lab[0][0]),16,'independent chosen velocity frame')
    frames=[vector(u) for u in frame_event['densities']];need(len(frames)==len(lab),'complete actual frame samples')
    for actual,u in zip(frames,lab):
        expected,scales=frame_transform(u,velocity)
        for value,wanted,scale in zip(actual,expected,scales):close(value,wanted,scale,64,'independent native velocity-frame transform')
    mean=vector(frame_event['mean']);same(mean,frames[0],'actual frame mean');need(admissible(cursor,mean,0.,0.),'valid frame mean')
    controls=[vector(p) for p in case['controls']];global_factor=1.;fallback=False;polys=[];stencil=None
    for c in range(5):
        cursor.pop('begin-component',c);nearby=[u[c] for u in frames[1:]];low=min([mean[c]]+nearby);high=max([mean[c]]+nearby);original_scale=max([1.]+[abs(u[c]) for u in lab])
        constant=high-low<=128*EPS*original_scale
        if constant:coefficients=[]
        else:
            if stencil is None:
                stencil=verify_stencil(cursor.pop('stencil',c),case,True,mean[c],variant,findings)
                for record,sample,value in zip(stencil['neighbours'],case['neighbours'],nearby):scalar_sample_same(record,vector(sample['centre']),matrix(sample['covariance']),value)
            coefficients=verify_solve(cursor.pop('solve',c),stencil,mean[c],nearby,True,variant,case['id']+'/'+str(c),findings)
            fallback=fallback or len(coefficients)<9
        # Inspect the actual component result, while consuming its full preceding
        # control/limiter sequence in chronological order.
        end=next((e for e in cursor.events[cursor.index:] if e['kind']=='component'),None);need(end is not None,'missing complete component result')
        poly=end['polynomial'];verify_poly(poly,case,mean[c],low,high,coefficients,True)
        if case['bound']:
            factor=1.
            for point in controls:
                event=cursor.pop('limit',c);same(vector(event['point']),point,'ordered limiter control');need(scalar(event['mean'])==mean[c] and scalar(event['lower'])==low and scalar(event['upper'])==high,'actual limiter component bounds')
                value,scale=evaluate(poly,point);delta=scalar(event['delta']);close(delta,value-mean[c],scale,64,'independent sampled polynomial delta')
                need(scalar(event['before'])==factor,'actual limiter before factor')
                if delta>0:factor=min(factor,(high-mean[c])/delta)
                if delta<0:factor=min(factor,(low-mean[c])/delta)
                need(scalar(event['after'])==factor,'actual native bound update')
            need(scalar(cursor.pop('limited',c)['rawFactor'])==factor,'complete raw limiter result');global_factor=min(global_factor,max(0,min(1,factor)))
        end=cursor.pop('component',c);need(end['polynomial']==poly,'component result identity')
        need(scalar(end['originalScale'])==original_scale and scalar(end['lower'])==low and scalar(end['upper'])==high,'actual original-data scale and constant threshold')
        need(end['bound']==case['bound'] and scalar(end['globalFactor'])==global_factor and end['fallback']==fallback,'actual shared component factor/fallback')
        polys.append(poly)
    deltas=[vector(d) for d in cursor.pop('deltas')['values']];need(len(deltas)==len(controls),'all actual control deltas')
    for point,delta in zip(controls,deltas):
        need(len(delta)==8 and all(v==0 for v in delta[5:]),'complete mean-free Euler lanes')
        for c in range(5):
            value,scale=evaluate(polys[c],point);close(delta[c],value-mean[c],scale,64,'independent full control delta tree')
    floors=cursor.pop('floors');density_floor=scalar(floors['density']);internal_floor=scalar(floors['energy'])
    close(density_floor,1e-12*mean[0],abs(density_floor),16,'density floor policy')
    exact_internal=F.from_float(mean[4])-sum(F.from_float(v)**2 for v in mean[1:4])/(2*F.from_float(mean[0]));close(internal_floor,1e-12*float(exact_internal),1e-12*(abs(mean[4])+abs(float(exact_internal-F.from_float(mean[4])))),32,'internal floor policy')
    reduced=not probe(cursor,global_factor,mean,deltas,density_floor,internal_floor)
    if reduced:
        need(probe(cursor,0.,mean,deltas,density_floor,internal_floor),'admissible zero backoff')
        low=0.;high=global_factor
        for index in range(48):
            mid=(low+high)/2;answer=probe(cursor,mid,mean,deltas,density_floor,internal_floor);event=cursor.pop('backoff')
            need(scalar(event['beforeLow'])==low and scalar(event['beforeHigh'])==high and scalar(event['mid'])==mid,'complete actual bisection inputs')
            if answer:low=mid
            else:high=mid
            need(scalar(event['low'])==low and scalar(event['high'])==high,'actual bisection branch/update')
        global_factor=.99*low
    selected=cursor.pop('selected');need(scalar(selected['factor'])==global_factor and selected['reduced']==reduced and selected['fallback']==fallback,'final 0.99 backoff/fallback result')
    states=cursor.pop('outputs')['states'];need(len(states)==len(controls),'complete final lab validation tree')
    for actual,point in zip(states,controls):verify_query(actual,polys,global_factor,velocity,point)
    result=case['result'];need(result['polynomials']==polys and scalar(result['factor'])==global_factor and result['reduced']==reduced and result['fallback']==fallback,'returned reconstruction result identity');same(vector(result['velocityFrame']),velocity,'returned velocity frame')
    points=controls+[vector(p) for p in case['cell']['volumePoints']];queries=result['queries'];need(len(queries)==len(points) and queries[:len(controls)]==states,'complete output/control/volume tree')
    values=[verify_query(q,polys,global_factor,velocity,p) for q,p in zip(queries,points)]
    volume=values[len(controls):]
    for c in range(8):
        recovered=seqsum(u[c]/len(volume) for u in volume);scale=max([abs(lab[0][c])]+[abs(u[c]) for u in volume]);close(recovered,lab[0][c],scale,1024,'independent final lab volume inventory mean')
    cursor.finished()

def verify_data(data):
    need(set(data)=={'schemaVersion','variant','cases'} and data['schemaVersion']==1 and data['variant'] in ['original','shared'],'capture schema/variant')
    specs=expected_cases();cases=data['cases'];need(len(cases)==191 and len({c['id'] for c in cases})==191 and {c['id'] for c in cases}==set(specs),'complete unique 191-case reconstruction cohort')
    findings=[]
    for case in cases:
        spec=specs[case['id']]
        try:
            verify_inputs(case,spec)
            if case['kind']=='gas':verify_gas(case,spec,data['variant'],findings)
            else:verify_scalar(case,spec,data['variant'],findings)
        except (ValueError,KeyError,IndexError,TypeError,OverflowError,ZeroDivisionError) as error:
            raise ValueError(case['id']+': '+str(error)) from error
    counts=collections.Counter(e['kind'] for c in cases for e in c['events']);need(counts['backoff']==192 and counts['component']==680 and counts['solve']==734 and counts['stencil']==178,'complete actual policy/reuse coverage')
    return {'schemaVersion':1,'variant':data['variant'],'cases':191,'successfulGas':136,'successfulScalar':48,'invalidInputs':7,'eventCounts':dict(sorted(counts.items())),'findings':findings,'scope':'actual reconstruction arithmetic and native rounded policy, sampled EOS and volume-mean contracts; no global positivity or empirical validation'}
def verify_source(root):
    root=Path(root);env=json.loads((root/'environment.json').read_text());source=root/'source'
    need(env['schemaVersion']==1 and env['workingTreeDirty'] is False and env['flags']==['-c','release','-Xswiftc','-warnings-as-errors'],'committed optimized capture producer')
    files={str(p.relative_to(source)):p for p in source.rglob('*') if p.is_file()};need(set(files)==set(env['sourceHashes']),'complete source/fixture/reference/script identities')
    for name,path in files.items():need(hashlib.sha256(path.read_bytes()).hexdigest()==env['sourceHashes'][name],'recorded source identity '+name)
    snapshots=json.loads((source/'Fixtures/QRReconstructionAdoption/source.json').read_text());need(snapshots['revision']=='b7d86c445d7aa40ed63bab1562e9c956b1c5c31e','protected original source checkpoint')
    for name,entry in snapshots['sources'].items():
        raw=(source/'Fixtures/QRReconstructionAdoption'/entry['snapshot']).read_bytes();need(hashlib.sha256(raw).hexdigest()==entry['sha256'] and hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()==entry['gitBlob'],'protected original snapshot')
    reference=json.loads((source/'Fixtures/QRReconstructionAdoption/References/source.json').read_text());need(reference['revision']=='00eac5537843c85c3c25a7ecef1120f49e8aa469' and reference['version']=='0.1.0-alpha.19','exact independent reference source')
    for name,sha in reference['sha256'].items():need(hashlib.sha256((source/'Fixtures/QRReconstructionAdoption/References'/name).read_bytes()).hexdigest()==sha,'reference source hash')
    versions={'original':('0.1.0-alpha.16','1977b38a66382533be902350b40e7084a2d1e9ca'),'shared':('0.1.0-alpha.19','00eac5537843c85c3c25a7ecef1120f49e8aa469')}
    with tempfile.TemporaryDirectory(prefix='qr-bindings-replay-') as scratch:
        for variant,(version,revision) in versions.items():
            pins=json.loads((root/variant/'Package.resolved').read_text())['pins'];need(len(pins)==1 and pins[0]['identity']=='continuumkit' and pins[0]['state']['version']==version and pins[0]['state']['revision']==revision,'exact original/shared Core pin')
            bindings=json.loads((root/variant/'bindings.json').read_text());need(bindings['variant']==variant,'source binding variant')
            for entry in bindings['sources']:
                compiled=(root/variant/'source/Sources/ReconstructionCapture'/Path(entry['path']).name).read_text();need(hashlib.sha256(compiled.encode()).hexdigest()==entry['compiledSHA256'],'compiled source hash')
                restored=compiled
                for patch in reversed(entry['patches']):
                    need(restored.count(patch['traced'])==1,'unique passive source binding');restored=restored.replace(patch['traced'],patch['original'])
                expected=(source/'Fixtures/QRReconstructionAdoption'/snapshots['sources'][entry['path']]['snapshot']).read_text() if variant=='original' else (source/entry['path']).read_text()
                need(restored==expected and hashlib.sha256(restored.encode()).hexdigest()==entry['sourceSHA256'],'byte-exact protected arithmetic restoration')
            # Rebuild the complete passive binding recipe from the exact committed
            # source, and compare every compiled fixture file and manifest.
            target=Path(scratch)/variant
            subprocess.run([sys.executable,'-B',str(source/'Scripts/prepare-qr-reconstruction-capture.py'),'--variant',variant,'--output',str(target)],check=True,stdout=subprocess.DEVNULL)
            need((target/'bindings.json').read_bytes()==(root/variant/'bindings.json').read_bytes(),'exact passive observation recipe')
            actual_files={str(p.relative_to(root/variant/'source')) for p in (root/variant/'source').rglob('*') if p.is_file()};expected_files={'Package.swift'}|{str(p.relative_to(target)) for p in (target/'Sources').rglob('*') if p.is_file()};need(actual_files==expected_files,'complete compiled source tree')
            for name in expected_files:need((target/name).read_bytes()==(root/variant/'source'/name).read_bytes(),'compiled fixture/source recipe')
            need(not any('/'+name+'.framework/' in (root/variant/'linkage.txt').read_text() for name in ['Metal','MetalKit','AppKit','SwiftUI']),'standalone CPU capture boundary')
    print('PASS exact producer/source/pins and byte-reversible actual arithmetic bindings')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('input',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--producer',type=Path);args=p.parse_args()
    if args.producer:verify_source(args.producer)
    report=verify_data(json.loads(args.input.read_text()));args.output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n');print('PASS complete independent source-bound reconstruction reference',report['variant'],report['cases'],report['eventCounts'])
