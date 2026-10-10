#!/usr/bin/env python3
"""Require complete unchanged wall/piston/reflection outputs and independent budgets."""
import argparse,json,math
from pathlib import Path
def require(v,label):
    if not v:raise ValueError(label)
def verify(root):
    original=(root/'original/report.json').read_bytes();shared=(root/'shared/report.json').read_bytes()
    require(original==shared,'complete report byte mismatch')
    data=json.loads(shared);require(data['schemaVersion']==1,'schema')
    require(len(data['wallCases'])==360,'complete ordinary wall tree')
    require(len({(v['density'],v['pressure'],v['velocity'],v['gamma']) for v in data['wallCases']})==360,'unique wall cases')
    require(len(data['wallStudy'])==8 and len(data['reflection'])==8 and len(data['pistons'])==12,'complete coupled tree')
    require([v['normalMach'] for v in data['wallStudy']]==[-6,-4,-2,-.1,0,.1,1,3],'wall study inputs')
    require({(v['cellLength'],v['cfl'],v['mach'],v['transport']) for v in data['reflection']}=={(h,.2,m,t) for h in [.1,.05] for m in [1.2,2] for t in ['limitedSSPRK2','conservedQuadraticSSPRK2']},'reflection inputs')
    for v in data['reflection']:
        require([f['arrivalFraction'] for f in v['frames']]==[.8,1,1.2,1.4],'complete reflection clocks')
        require(all(abs(f['time']-v['arrivalTime']*f['arrivalFraction'])<1e-14 for f in v['frames']) and abs(v['frames'][-1]['time']-v['duration'])<1e-14,'reflection physical clocks')
        require(v['steps']>0 and abs(v['relativeMassChange'])<1e-11 and abs(v['relativeEnergyChange'])<1e-11 and len(v['momentumBudgetResidual'])==3 and all(abs(x)<1e-10 for x in v['momentumBudgetResidual']),'reflection conservation budgets')
    require({(p['spacing'],p['velocity'],p['reconstruction']) for p in data['pistons']}=={(h,v,r) for h in [.05,.025,.0125] for v in [-20,20] for r in ['constant','minmod']},'piston inputs')
    total=0
    for p in data['pistons']:
        require(len(p['frames'])==33 and [f['time'] for f in p['frames']]==[p['duration']*i/32 for i in range(33)],'complete declared frame clocks')
        require(len(p['intervals'])==p['steps'] and p['steps']>0,'all accepted physical intervals')
        end=0.0;impulse=work=0.0
        for step in p['intervals']:
            require(step['time']==end and step['duration']>0,'continuous accepted interval clocks')
            end=step['time']+step['duration'];impulse+=step['impulse'];work+=step['work']
        require(abs(end-p['duration'])<1e-14,'terminal accepted clock')
        require(abs(impulse-p['pistonImpulse'])<1e-11 and abs(work-p['work'])<1e-11,'complete wall load integration')
        amount=[sum(c['amount'][a] for c in p['cells']) for a in range(8)]
        initial=p['initialAmount'];require(abs(amount[0]-initial[0])<1e-11*initial[0],'mass budget')
        require(abs(amount[4]+p['work']-initial[4])<1e-10*initial[4],'gas/wall energy budget')
        for a in range(3):require(abs(amount[a+1]+p['impulse'][a]-initial[a+1])<1e-10,'momentum/wall impulse budget')
        for f in p['frames']:
            require(f['cells'] and all(c['volume']>0 and c['pressure']>0 and len(c['amount'])==8 and all(math.isfinite(v) for v in c['amount']) for c in f['cells']),'complete positive native cell states')
            total+=len(f['cells'])
    env=json.loads((root/'environment.json').read_text());require(env['workingTreeDirty'] is False,'dirty producer')
    pins=json.loads((root/'shared/consumer-Package.resolved').read_text())['pins']
    require(any(p['identity']=='continuumkit' and p['state']=={'version':'0.1.0-alpha.13','revision':'b6ff3ca28eb96bbac23ec15d93a13afda99b2be9'} for p in pins),'exact released shared dependency')
    return {'schemaVersion':1,'status':'passed','candidate':env['candidate'],'wallCases':360,'pistonRuns':12,'reflectionHistories':8,'nativeFrameCells':total,'completeReports':'byte-identical','independentBudgets':'mass/momentum/energy and complete accepted wall loads'}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();d=verify(a.root)
    (a.root/'verification.json').write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS complete original/shared wall, native piston states/intervals and reflection reports;',d['nativeFrameCells'],'frame cells')
