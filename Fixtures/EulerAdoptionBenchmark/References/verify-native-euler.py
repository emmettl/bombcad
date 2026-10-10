#!/usr/bin/env python3
"""Complete native conformance, scalar SI ledgers and independent continuum refinement references."""
import argparse,cmath,itertools,json,math,struct,sys
from pathlib import Path
EPS=sys.float_info.epsilon
def require(v,label):
 if not v: raise ValueError(label)
def near(a,b,scale=None,label='rounding budget'):
 require(abs(a-b)<=256*EPS*max(abs(a),abs(b),abs(scale or 0),1e-300),label)
def native(s,positive=False):
 require(len(s['values'])==len(s['bits'])==13,'complete 13-lane native snapshot')
 v=[struct.unpack('>d',int(b,16).to_bytes(8,'big'))[0] for b in s['bits']]
 require(all(math.isfinite(x) for x in v),'finite native values')
 require(all(float(a)==b for a,b in zip(s['values'],v)),'native values/bits agree')
 if positive:
  V=v[0]; q=v[1:9]; rho=q[0]/V
  require(V>0 and q[0]>0 and all(x==0 for x in q[5:]),'positive occupied native state and reserved lanes')
  u=[x/q[0] for x in q[1:4]]; K=0.5*q[0]*math.fsum(x*x for x in u)
  require(q[4]>K and v[12]>0,'positive independent internal energy')
  for a,b in zip(u,v[9:12]):near(a,b,label='independent velocity view')
  near(v[12],(1.4-1)*(q[4]-K)/V,(abs(q[4])+K)/V,'independent pressure view')
 return v
def wall_pressure(rho,p,u):
 c=math.sqrt(1.4*p/rho)
 if u<=0:return p*max(0,1+0.2*u/c)**7
 # Independently find the Hugoniot pressure by bisection of the velocity jump.
 A=2/(2.4*rho); B=p/6
 def jump(P):return (P-p)*math.sqrt(A/(P+B))
 low=p; high=2*p
 while jump(high)<u: high*=2
 for _ in range(100):
  mid=(low+high)/2
  if jump(mid)<u:low=mid
  else:high=mid
 return (low+high)/2
def primitive(V,rho,u,p):return [V,V*rho,*[V*rho*x for x in u],V*p/(1.4-1)+0.5*V*rho*math.fsum(x*x for x in u)]
def match_primitive(s,V,rho,u,p):
 v=native(s)
 for a,b in zip(v[:6],primitive(V,rho,u,p)):near(a,b,label='declared case primitive input')
def inspect_interval(i):
 before=[native(c) for c in i['input']]
 for f in i['faces']:
  for s in [f.get('left'),f.get('right')]:
   if s is not None:native(s)
 for w in i['walls']:
  if w.get('state') is not None:native(w['state'])
 if i.get('failure'):
  require(i.get('result') is None and i.get('impulses') is None and i.get('work') is None,'failed trial publishes no partial state')
  return 0
 before=[native(c,True) for c in i['input']];after=[native(c,True) for c in i['result']]
 require(len(before)==len(after),'complete returned cell tree')
 dt=i['duration'];require(dt>0 and math.isfinite(dt),'positive native duration')
 impulses=i['impulses'];work=i['work']
 require(len(impulses)==len(work)==len(i['walls']),'complete ordered wall result tree')
 rates=[0.0]*len(before);volume_rates=[0.0]*len(before)
 packets=[[0.0]*8 for _ in before];scales=[[abs(x) for x in v[1:9]] for v in before]
 for f in i['faces']:
  a,b=f['a'],f['b'];n=f['normal'];area=f['area']
  require(0<=a<len(before) and 0<=b<len(before) and a!=b and area>=0,'paired occupied face indices/area')
  near(math.fsum(x*x for x in n),1,label='unit face normal')
  states=[native(f['left'],True) if f.get('left') is not None else before[a],native(f['right'],True) if f.get('right') is not None else before[b]]
  physical=[];intensive=[];speeds=[]
  for v in states:
   rho=v[1]/v[0];u=v[9:12];p=v[12];un=math.fsum(x*y for x,y in zip(u,n));q=[x/v[0] for x in v[1:9]]
   intensive.append(q);speeds.append(abs(un)+math.sqrt(1.4*p/rho))
   physical.append([rho*un,*[q[k+1]*un+p*n[k] for k in range(3)],(q[4]+p)*un,0,0,0])
  speed=max(speeds);rates[a]+=area*speed;rates[b]+=area*speed
  for k in range(8):
   packet=dt*area*(0.5*(physical[0][k]+physical[1][k])-0.5*speed*(intensive[1][k]-intensive[0][k]))
   packets[a][k]-=packet;packets[b][k]+=packet
   scales[a][k]+=abs(packet);scales[b][k]+=abs(packet)
 for slot,w in enumerate(i['walls']):
  a=w['cell'];n=w['normal'];u=w['velocity'];area=w['area'];v=native(w['state'],True) if w.get('state') is not None else before[a]
  require(len(n)==len(u)==3 and len(impulses[slot])==3,'complete wall vector')
  near(math.fsum(x*x for x in n),1,label='unit wall normal')
  un=math.fsum((x-y)*z for x,y,z in zip(v[9:12],u,n));rho=v[1]/v[0];p=v[12]
  P=wall_pressure(rho,p,un);c=math.sqrt(1.4*p/rho)
  wave=math.sqrt((2.4*P+0.4*p)/(2*rho)) if un>0 else c
  wn=math.fsum(x*y for x,y in zip(u,n))
  rates[a]+=area*(abs(un)+wave+abs(wn));volume_rates[a]+=area*wn
  imp=[dt*area*P*x for x in n];W=math.fsum(x*y for x,y in zip(imp,u))
  for actual,expected in zip(impulses[slot],imp):near(actual,expected,dt*area*P,'independent Hugoniot/rarefaction traction')
  near(work[slot],W,math.fsum(abs(x*y) for x,y in zip(imp,u)),'work delivered to prescribed wall')
  load=[0,*imp,W,0,0,0]
  for k in range(8):packets[a][k]-=load[k];scales[a][k]+=abs(load[k])
 limits=[]
 for slot,(a,b) in enumerate(zip(before,after)):
  near(b[0],a[0]+dt*volume_rates[slot],a[0],'prescribed wall geometric volume')
  for k in range(8):near(b[k+1],a[k+1]+packets[slot][k],scales[slot][k],'independent per-cell Euler extensive balance')
  if rates[slot]>0:limits.append(i['cfl']*a[0]/rates[slot])
  if volume_rates[slot]<0:limits.append(i['cfl']*a[0]/-volume_rates[slot])
 limit=min(limits,default=math.inf)
 recorded=struct.unpack('>d',int(i['limitBits'],16).to_bytes(8,'big'))[0]
 if math.isfinite(limit):
  near(recorded,limit,label='incident-characteristic and geometric CFL clock')
  near(i['limit'],recorded,label='limit values/bits')
  require(dt<=recorded,'physical interval respects declared clock')
 else:require(i['limit'] is None and recorded==math.inf,'unlimited isolated state')
 for k in range(8):
  observed=math.fsum(b[k+1]-a[k+1] for a,b in zip(before,after))
  expected=0 if k in [0,5,6,7] else -math.fsum((w[k-1] for w in impulses) if k<4 else work)
  near(observed,expected,math.fsum(s[k] for s in scales),'complete external mass/momentum/energy ledger')
 return len(after)

FAILURES={'index':('flux.invalidFace','maximumStep'),'normal':('flux.invalidFace','maximumStep'),'wall':('flux.invalidWall','maximumStep'),'cflLow':('flux.invalidStep','maximumStep'),'cflHigh':('flux.invalidStep','maximumStep'),'duration':('flux.invalidStep','advance'),'unstable':('flux.unstableStep','advance'),'host':('packet.invalidState','maximumStep'),'tracePositivity':('packet.invalidState','advance'),'dryFace':('flux.invalidFace','maximumStep')}
def verify(root,reports=None,metadata=None):
 original,shared=reports if reports is not None else (json.loads((root/'original.json').read_text()),json.loads((root/'shared.json').read_text()))
 require(original==shared,'complete original/shared native fields, clocks, loads, inputs and failures')
 expected={"face/"+'/'.join(map(str,p)) for p in itertools.product(range(3),range(3),range(3),range(3),range(3),range(2))}
 expected|={"wall/"+'/'.join(map(str,p)) for p in itertools.product(range(3),repeat=5)}
 expected|={'failure/'+s for s in FAILURES}|{k+'/'+str(n) for k in ['acoustic','contact','shock'] for n in [32,64,128]}
 expected|={'acousticTime/'+str(k) for k in range(3)}
 require(len(shared)==len(expected)==751 and {c['id'] for c in shared}==expected,'complete unique 751-case tree')
 env=json.loads((root/'environment.json').read_text());summary=json.loads((root/'summary.json').read_text())
 if metadata is not None:env=metadata.get('environment',env)
 require(env['workingTreeDirty'] is False and env['candidate']==summary['candidate'],'clean committed producer')
 pins=json.loads((root/'consumer-Package.resolved').read_text())['pins']
 if metadata is not None:pins=metadata.get('pins',pins)
 require(len(pins)==1 and pins[0]['identity']=='continuumkit' and pins[0]['state']['revision']==summary['candidate'],'exact public fetched Git producer')
 if summary['version']:require(pins[0]['state']['version']==summary['version'],'exact semantic version pin')
 errors={k:[] for k in ['acoustic','contact','shock']};temporal=[];native_count=0;interval_count=0
 for case in shared:
  kind=case['kind'];ids=case['id'].split('/');ints=case['intervals'];require(len(ints)>0,'nonempty native history')
  if kind in ['face','wall','failure']:require(len(ints)==1,'single prescribed trial')
  if kind=='failure':
   require((ints[0].get('failure'),ints[0].get('failureStage'))==FAILURES[ids[1]],'exact declared failure category and stage')
  else:require(all(i.get('failure') is None for i in ints),'supported native case rejected')
  if kind in ['face','wall']:
   di,pi,vi,ni=map(int,ids[1:5]);rho=[.25,1,7][di];p=[1,100,101325][pi];u=[[0,0,0],[1,-2,3],[100,50,-25]][vi];n=[[1,0,0],[.6,.8,0],[0,0,1]][ni];i=ints[0]
   require(i['time']==0 and i['cfl']==.4 and case['parameters']=={},'matrix interval identity')
   near(i['duration'],.001*i['limit'],label='declared trial duration')
   if kind=='face':
    si,traced=map(int,ids[5:]);V=[1e-6,1,1e3][si]
    require(len(i['input'])==2 and len(i['faces'])==1 and i['walls']==[],'complete face input tree')
    match_primitive(i['input'][0],V,rho,u,p);match_primitive(i['input'][1],2*V,1.25*rho,[-.5*x for x in u],.75*p)
    f=i['faces'][0];require((f['a'],f['b'],f['normal'],f['area'])==(0,1,n,.7),'declared face graph')
    if traced:
     match_primitive(f['left'],.5*V,.9*rho,u,1.2*p);match_primitive(f['right'],3*V,1.1*rho,[-.5*x for x in u],.8*p)
    else:require(f.get('left') is None and f.get('right') is None,'untraced face identity')
   else:
    require(len(i['input'])==1 and i['faces']==[] and len(i['walls'])==1,'complete wall input tree')
    match_primitive(i['input'][0],1,rho,u,p);w=i['walls'][0];speed=[-.5,0,.5][int(ids[5])]*math.sqrt(1.4*p/rho)
    require((w['cell'],w['normal'],w['area'])==(0,n,.7) and w.get('state') is None,'declared wall identity')
    for a,b in zip(w['velocity'],[x*speed for x in n]):near(a,b,label='prescribed wall velocity')
  for i in ints:native_count+=inspect_interval(i);interval_count+=1
  if kind not in errors and kind!='acousticTime':continue
  is_time=kind=='acousticTime';n=64 if is_time else int(ids[1]);h=1/n;end=.05 if kind=='shock' else .15
  cfl=[.4,.2,.1][int(ids[1])] if is_time else .4
  parameters={'cells':n,'duration':end}
  if is_time:parameters['cfl']=cfl
  require(case['parameters']==parameters,'refinement declared grid/duration/CFL')
  count=n+2 if kind=='shock' else n
  c=math.sqrt(1.4);up=primitive(h,1,[3-2*c,0,0],1);down=primitive(h,8/3,[3-.75*c,0,0],4.5)
  require(ints[0]['time']==0,'native history begins at zero')
  for step,i in enumerate(ints):
   require(len(i['input'])==len(i['result'])==count and i['walls']==[] and i['cfl']==cfl,'complete native wave grid')
   graph=[(f['a'],f['b'],f['normal'],f['area']) for f in i['faces']]
   require(graph==[(k,k+1 if kind=='shock' else (k+1)%n,[1,0,0],1) for k in range(n+1 if kind=='shock' else n)],'complete native interface graph')
   require(all(f.get('left') is None and f.get('right') is None for f in i['faces']),'first-order wave traces')
   if step:
    prev=ints[step-1];near(i['time'],prev['time']+prev['duration'],label='complete physical native clock')
    require(i['input'][1:-1] == prev['result'][1:-1] if kind=='shock' else i['input']==prev['result'],'complete interval continuity')
   if kind=='shock':
    for state,prescribed in [(i['input'][0],down),(i['input'][-1],up)]:
     for a,b in zip(native(state)[:6],prescribed):near(a,b,label='prescribed external ghost reservoir')
  near(ints[-1]['time']+ints[-1]['duration'],end,label='complete final physical time')
  first=ints[0]['input'];last=ints[-1]['result'];err=[]
  for k in range(n):
   idx=k+1 if kind=='shock' else k;x=(k+.5)*h
   sine=(math.cos(2*math.pi*k*h)-math.cos(2*math.pi*(k+1)*h))/(2*math.pi*h)
   if kind=='shock':
    initial=down if k<n/4 else up
    for a,b in zip(native(first[idx])[:6],initial):near(a,b,label='normal-shock initial state')
    weight=max(0,min(1,(.25+3*end-k*h)/h));expected=[weight*a+(1-weight)*b for a,b in zip(down,up)]
    actual=native(last[idx]);err.append(sum(abs(actual[j]-expected[j])/(abs(down[j]-up[j]) or 1) for j in [1,2,5])/3)
   else:
    eps=.1 if kind=='contact' else 1e-6;speed=.7 if kind=='contact' else .2+c
    match_primitive(first[k],h,1+eps*sine,[.7 if kind=='contact' else .2+eps*c*sine,0,0],1 if kind=='contact' else 1+1.4*eps*sine)
    phase=speed*end;s=(math.cos(2*math.pi*(k*h-phase))-math.cos(2*math.pi*((k+1)*h-phase)))/(2*math.pi*h)
    if is_time:
     eigenvalue=-(.2+c)/h*(1-cmath.exp(-2j*math.pi*h))
     s=(cmath.exp(2j*math.pi*x+eigenvalue*end)*(math.sin(math.pi*h)/(math.pi*h))).imag
    final=native(last[k]);err.append(abs(final[1]/h-(1+eps*s))/eps)
    if kind=='contact':near(final[12],1,10,'contact constant pressure');near(final[9],.7,10,'contact constant velocity')
    else:
     require(abs(final[12]-(1+1.4*eps*s))/(1.4*eps)<.3,'acoustic pressure phase/amplitude')
     require(abs(final[9]-(.2+eps*c*s))/(eps*c)<.3,'acoustic velocity phase/amplitude')
  (temporal if is_time else errors[kind]).append((cfl if is_time else n,math.fsum(err)/n))
 for kind,rows in errors.items():
  rows.sort();require([n for n,e in rows]==[32,64,128],'complete refinement levels')
  for (_,a),(_,b) in zip(rows,rows[1:]):require(a/b>(1.2 if kind=='shock' else 1.6),'independent '+kind+' refinement rate')
  require(rows[-1][1] < (.12 if kind=='shock' else .06),'independent finest '+kind+' error bound')
 temporal.sort(reverse=True)
 require([cfl for cfl,e in temporal]==[.4,.2,.1],'complete independent temporal levels')
 for (_,a),(_,b) in zip(temporal,temporal[1:]):require(a/b>1.6,'independent temporal refinement rate')
 require(temporal[-1][1]<.01,'independent finest temporal error bound')
 return {'schemaVersion':1,'status':'passed','cases':751,'returnedNativeCells':native_count,'intervals':interval_count,'refinementErrors':errors,'temporalErrors':temporal,'scope':'native source conformance, SI scalar balances/characteristics and analytic continuum references; no empirical blast validation'}
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args()
 d=verify(a.root);(a.root/'verification.json').write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS Euler native conformance and independent shock/contact/acoustic refinement:',d['returnedNativeCells'],'cells')
