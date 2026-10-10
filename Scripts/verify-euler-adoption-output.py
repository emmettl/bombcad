#!/usr/bin/env python3
"""Complete app-owned Euler/SSPRK2 histories with independent frozen scalar reference checks."""
import argparse,hashlib,importlib.util,itertools,json,math
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
reference=repo/'Fixtures/EulerAdoptionBenchmark/References/verify-native-euler.py'
manifest=json.loads(reference.with_name('source.json').read_text())
assert hashlib.sha256(reference.read_bytes()).hexdigest()==manifest['sha256']
assert manifest['revision']=='1977b38a66382533be902350b40e7084a2d1e9ca'
spec=importlib.util.spec_from_file_location('native_euler_reference',reference)
ref=importlib.util.module_from_spec(spec);spec.loader.exec_module(ref)
def require(v,label):
 if not v:raise ValueError(label)
def native(c):return {'values':[c['volume'],*c['amount'],*c['velocity'],c['pressure']],'bits':[format(v,'x') for v in c['bits']]}
def states(cells):return [ref.native(native(c),True) for c in cells]
def faces(f):return [{**v,'left':native(v['left']) if v.get('left') else None,'right':native(v['right']) if v.get('right') else None} for v in f]
def walls(w):return [{**v,'state':native(v['state']) if v.get('state') else None} for v in w]
def load_bits(loads):
 for w in loads:
  require(len(w['impulse'])==3 and len(w['bits'])==4,'complete ordered native wall load')
  for value,b in zip([*w['impulse'],w['work']],w['bits']):
   require(math.isfinite(value) and value==ref.struct.unpack('>d',b.to_bytes(8,'big'))[0],'finite native load values/bits')
def stage(i,input,result,stage_faces,stage_walls,limit):
 load_bits(result['loads'])
 return ref.inspect_interval({'time':i['time'],'duration':i['duration'],'cfl':.2,'limit':limit,
  'limitBits':format(int.from_bytes(ref.struct.pack('>d',limit),'big'),'x'),'input':[native(c) for c in input],
  'faces':faces(stage_faces),'walls':walls(stage_walls),'result':[native(c) for c in result['cells']],
  'impulses':[w['impulse'] for w in result['loads']],'work':[w['work'] for w in result['loads']], 'failure':None})
def verify(root,reports=None):
 if reports is None:
  a=(root/'original/euler-report.json').read_bytes();b=(root/'shared/euler-report.json').read_bytes()
  require(a==b,'complete original/shared Euler report bytes');d=json.loads(b)
 else:d=reports
 require(d['schemaVersion']==1 and len(d['runs'])==40,'complete Euler schema/run count')
 identities={(r['kind'],r['integration'],r['profile'],r['resolution'],r['rotation'],r['wallSpeed']) for r in d['runs']}
 expected={('tube',i,p,n,0,v) for i,p,n,v in itertools.product(['euler','ssprk2'],['uniform','pulse'],[16,32],[-3,0,3])}
 expected|={('group',i,p,h,a,0) for i,p,h,a in itertools.product(['euler','ssprk2'],['uniform','pulse'],[.4,.2],[0,.23])}
 require(identities==expected,'complete unique tube/group/integration/profile tree')
 count=0;intervals=0;group_cells=0;tube_cells=0
 for run in d['runs']:
  rows=run['frames'];require(len(rows)==(6 if run['kind']=='tube' else 2),'complete accepted history')
  previous=None;time=0
  for i in rows:
   require(i['time']==time and i['duration']>0 and i['duration']<=i['limit'],'complete physical Euler clocks')
   ref.near(i['duration'],.02*i['limit'],label='declared bounded interval')
   time+=i['duration'];input=i['input'];result=i['result'];load_bits(result['loads'])
   if previous is not None:require(input==previous,'complete interval cell continuity')
   previous=result['cells'];before=states(input);after=states(result['cells']);require(len(before)==len(after),'complete native final state')
   require(all(f.get('left') is not None and f.get('right') is not None for f in i['faces']),'complete actual first-stage reconstruction traces')
   count+=stage(i,input,i['first'],i['faces'],i['walls'],i['limit'])
   if run['kind']=='tube':
    n=int(run['resolution']);require(len(input)==n and len(i['faces'])==n-1 and len(i['walls'])==2,'complete tube mesh')
    require([(f['a'],f['b'],f['normal'],f['area']) for f in i['faces']]==[(k,k+1,[1,0,0],.01) for k in range(n-1)],'ordered actual tube interface graph')
    require(i['walls'][0]['cell']==0 and i['walls'][0]['normal']==[-1,0,0] and i['walls'][0]['velocity']==[0,0,0],'tube fixed-wall identity')
    require(i['walls'][1]['cell']==n-1 and i['walls'][1]['normal']==[1,0,0] and i['walls'][1]['velocity']==[run['wallSpeed'],0,0],'tube prescribed-wall identity')
    tube_cells+=len(after)
   else:
    members=run['members'];flat=[n for group in members for n in group]
    require(len(members)==len(input) and len(set(flat))==len(flat) and all(0<=n<round(2/run['resolution'])**3 for n in flat),'complete group membership identity')
    grid=run['nativeGrid'];require(len(grid)==round(2/run['resolution'])**3,'complete ungrouped native geometry grid')
    wet={n for n,c in enumerate(grid) if c['volume']>0}
    require(set(flat)==wet and all(members),'complete wet native member support')
    for c in grid:
     v=ref.native(native(c),c['volume']>0)
     if v[0]==0:require(all(x==0 for x in v[1:9]),'empty dry native grid packet')
    scattered=i['scattered'];require(len(scattered)==len(grid),'complete actual scattered native field')
    for n,c in enumerate(scattered):
     require(c['volume']==grid[n]['volume'],'scattered original volume identity')
     v=ref.native(native(c),c['volume']>0)
     if v[0]==0:require(all(x==0 for x in v[1:9]),'empty scattered dry packet')
    for k in range(8):ref.near(math.fsum(c['amount'][k] for c in scattered),math.fsum(c['amount'][k] for c in result['cells']),math.fsum(abs(c['amount'][k]) for c in result['cells']),'complete scatter extensive budget')
    if i['time']==0:
     for k in range(8):ref.near(math.fsum(c['amount'][k] for c in grid),math.fsum(c['amount'][k] for c in input),math.fsum(abs(c['amount'][k]) for c in grid),'initial actual aggregation budget')
    require(all(w['velocity']==[0,0,0] for w in i['walls']),'stationary grouped walls')
    group_cells+=len(after)
   if run['integration']=='euler':
    require(result==i['first'] and i.get('second') is None and i.get('secondFaces') is None and i.get('stageLimit') is None,'first-order complete result identity')
   else:
    require(i.get('second') is not None and i.get('secondFaces') is not None and i.get('secondWalls') is not None and i['stageLimit']>=i['duration'],'complete accepted SSPRK2 stages')
    require(all(f.get('left') is not None and f.get('right') is not None for f in i['secondFaces']),'complete actual second-stage reconstruction traces')
    count+=stage(i,i['first']['cells'],i['second'],i['secondFaces'],i['secondWalls'],i['stageLimit'])
    second=states(i['second']['cells']);require(len(second)==len(input),'complete second-stage cells')
    for old,new,out in zip(before,second,after):
     for k in range(9):ref.near(out[k],(old[k]+new[k])/2,abs(old[k])+abs(new[k]),'extensive/volume two-stage mean')
    require(len(result['loads'])==len(i['first']['loads'])==len(i['second']['loads']),'complete matching staged load tree')
    for out,a,b in zip(result['loads'],i['first']['loads'],i['second']['loads']):
     for x,y,z in zip([*out['impulse'],out['work']],[*a['impulse'],a['work']],[*b['impulse'],b['work']]):ref.near(x,(y+z)/2,abs(y)+abs(z),'matching two-stage load mean')
   require(len(result['loads'])==len(i['walls']),'final ordered wall load tree')
   for k in range(5):
    change=math.fsum(b[k+1]-a[k+1] for a,b in zip(before,after))
    load=0 if k==0 else math.fsum(w['impulse'][k-1] if k<4 else w['work'] for w in result['loads'])
    ref.near(change,-load,math.fsum(abs(a[k+1])+abs(b[k+1]) for a,b in zip(before,after)),'independent composed extensive wall budget')
   if run['profile']=='uniform' and run['wallSpeed']==0:
    for v in after:require(abs(v[1]/v[0]/1.225-1)<1e-10 and abs(v[12]/101325-1)<1e-10 and max(abs(x) for x in v[9:12])<1e-8,'uniform resting coupled field')
   intervals+=1
 require(len(d['fractionalFlux'])==6 and {(v['smallestVolume'],v['reflectingWalls']) for v in d['fractionalFlux']}==set(itertools.product([.001,.00025,.0000625],[False,True])),'complete public fractional pressure-pulse tree')
 for v in d['fractionalFlux']:
  require(v['duration']==.0005 and v['steps']>0 and v['minimumStep']>0 and v['minimumPressure']>0 and abs(v['relativeMassChange'])<1e-11 and abs(v['relativeEnergyChange'])<1e-11 and max(abs(x) for x in v['momentumBudgetResidual'])<1e-9,'public fractional pulse clock/positivity/budgets')
 env=json.loads((root/'environment.json').read_text());require(env['workingTreeDirty'] is False,'clean Euler producer')
 require(env['baseline']=='586ed4e4780267049beedd197cac2aa9cdd01ec0','immutable actual app Euler baseline')
 require(env['corePin']=={'version':'0.1.0-alpha.16','revision':'1977b38a66382533be902350b40e7084a2d1e9ca'},'exact public-assembly release pin')
 for variant,version,revision in [('original','0.1.0-alpha.14','f5543e3c336a80ec86868c3f0f245b688dfba148'),('shared','0.1.0-alpha.16','1977b38a66382533be902350b40e7084a2d1e9ca')]:
  pins=json.loads((root/variant/'consumer-Package.resolved').read_text())['pins']
  require(any(p['identity']=='continuumkit' and p['state']=={'version':version,'revision':revision} for p in pins),'complete actual original/shared app dependency identity')
 return {'schemaVersion':1,'status':'passed','candidate':env['candidate'],'tubeHistories':24,'groupHistories':16,'acceptedIntervals':intervals,'tubeFinalFrameCells':tube_cells,'groupFinalFrameCells':group_cells,'returnedStageCells':count,'completeReports':'byte-identical','scope':'actual app Euler and limiter/group SSPRK2 results, full replayed stages/traces/loads; no app math or empirical blast claim'}
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();d=verify(a.root)
 (a.root/'euler-verification.json').write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS complete app Euler stages and independent SI/load/CFL/composition checks:',d['returnedStageCells'],'stage cells')
