#!/usr/bin/env python3
"""Require complete native packet-adoption histories and independent reservoir/wall ledgers."""
import argparse,itertools,json,math,struct
from pathlib import Path

def require(v,label):
    if not v:raise ValueError(label)
def cells(states):
    decoded=[]
    for s in states:
        require(len(s['amount'])==8 and len(s['velocity'])==3 and len(s['bits'])==13,'complete native packet')
        raw=[s['volume'],*s['amount'],*s['velocity'],s['pressure']]
        values=[struct.unpack('>d',int(b).to_bytes(8,'big'))[0] for b in s['bits']]
        require(all(math.isfinite(v) and v==float(x) for v,x in zip(values,raw)),'finite native values/bits')
        volume=values[0];amount=values[1:9];velocity=values[9:12];pressure=values[12]
        require(volume>=0 and all(x==0 for x in amount[5:]),'native volume/reserved lanes')
        if volume:require(amount[0]>0 and pressure>0,'positive wet packet')
        else:require(all(x==0 for x in amount),'empty dry packet')
        decoded.append((volume,amount,velocity,pressure))
    return decoded
def total(states):return [math.fsum(s[1][a] for s in states) for a in range(8)]
def verify(root):
    a=(root/'original/packet-report.json').read_bytes();b=(root/'shared/packet-report.json').read_bytes();require(a==b,'complete packet report byte mismatch');d=json.loads(b)
    require(d['schemaVersion']==1,'packet schema')
    require(len(d['remaps'])==2 and {r['profile'] for r in d['remaps']}=={'uniform','nonuniform'},'complete remap profiles')
    remap_cells=0
    for r in d['remaps']:
        initial=cells(r['initial']);require(len(initial)==3,'initial remap cells');before=total(initial)
        require(len(r['frames'])==32 and r['rejectedIntervals']==31,'actual capacity/refinement history')
        end=0.0
        for f in r['frames']:
            require(f['start']==end and f['end']>f['start'] and f['maximumOutflowFraction']<=1 and f['transfers']>0,'accepted remap intervals')
            end=f['end'];state=cells(f['cells']);require(len(state)==3,'all remap native cells');after=total(state)
            for axis in range(5):require(abs(after[axis]-before[axis])<1e-8,'closed remap extensive budget')
            remap_cells+=len(state)
        require(end==1 and r['final']==r['frames'][-1]['cells'],'terminal remap identity')
    identities={(r['spacing'],r['rotation'],r['integration'],r['quadratic'],r['profile']) for r in d['moving']}
    require(len(d['moving'])==32 and identities==set(itertools.product([.4,.2],[0,.23],['euler','heun'],[False,True],['uniform','nonuniform'])),'complete moving field tree')
    moving_cells=0;moving_intervals=0;opened=closed=0
    for r in d['moving']:
        count=round(2/r['spacing'])**3;old=cells(r['initial']);require(len(old)==count,'all initial moving cells');require(len(r['frames'])==4,'complete physical moving intervals')
        require(r['velocity']==[30,10,-4],'moving frame convention')
        for i,f in enumerate(r['frames']):
            require(f['time']==i*2e-7 and f['duration']==2e-7 and f['duration']<=f['maximumStep'],'accepted moving clocks/CFL')
            state=cells(f['cells']);require(len(state)==count,'all moving native cells')
            require(len(f['reservoirExchange'])==8 and all(math.isfinite(v) for v in f['reservoirExchange']),'complete reservoir exchange')
            require(len(f['wallImpulses'])==len(f['wallMoments'])==len(f['wallWork'])>0 and all(len(v)==3 for v in f['wallImpulses']+f['wallMoments']),'complete sampled wall loads')
            members=[n for group in f['members'] for n in group]
            require(len(f['members'])==f['groupCount'] and len(set(members))==len(members) and all(0<=n<count for n in members),'native partition identities')
            require({n for n,s in enumerate(state) if s[0]>0}<=set(members),'complete wet group support')
            before=total(old);after=total(state);reservoir=f['reservoirExchange'];impulse=[math.fsum(p[a] for p in f['wallImpulses']) for a in range(3)];work=math.fsum(f['wallWork'])
            require(abs(after[0]-before[0]-reservoir[0])<1e-10,'moving mass/reservoir budget')
            for axis in range(3):require(abs(after[axis+1]-before[axis+1]-reservoir[axis+1]+impulse[axis])<1e-8,'moving momentum/reservoir/wall budget')
            require(abs(after[4]-before[4]-reservoir[4]+work)<1e-6,'moving energy/reservoir/wall budget')
            require(abs(work-sum(a*b for a,b in zip(r['velocity'],impulse)))<1e-9,'same wall impulse/work convention')
            if r['profile']=='uniform':
                for v,amount,u,p in state:
                    if v:require(abs(amount[0]/v/1.225-1)<1e-8 and abs(p/101325-1)<1e-8 and max(abs(a-b) for a,b in zip(u,r['velocity']))<1e-6,'uniform moving field contract')
            opened+=sum(a[0]==0 and b[0]>0 for a,b in zip(old,state));closed+=sum(a[0]>0 and b[0]==0 for a,b in zip(old,state))
            old=state;moving_cells+=len(state);moving_intervals+=1
    require(opened>0 and closed>0,'actual wet/dry topology transitions')
    require([r['steps'] for r in d['fractionalGas']]==[1,4,16,64],'sealed work refinement tree')
    for r in d['fractionalGas']:require(abs(r['massChange'])<1e-12 and abs(r['energyBudgetResidual'])<1e-8 and abs(r['bodyWallWork']+r['gasWallWork'])<1e-12,'sealed gas/wall work budget')
    require(len(d['geometryRemap'])==3 and {r['cellSize'] for r in d['geometryRemap']}=={.2,.1,.05},'geometry remap refinement tree')
    for r in d['geometryRemap']:require(abs(r['relativeMassChange'])<1e-10 and abs(r['relativeEnergyChange'])<1e-10 and max(abs(v) for v in r['momentumChange'])<1e-9,'geometry remap budgets')
    require(len(d['connectedGas'])==4 and {(r['cellSize'],r['rotation']) for r in d['connectedGas']}==set(itertools.product([.2,.1],[0,.23])),'static connected gas tree')
    for r in d['connectedGas']:require(abs(r['relativeMassChange'])<1e-10 and abs(r['relativeEnergyChange'])<1e-10,'static connected gas budgets')
    require(len(d['pistonCrossing'])==4 and {(r['cellLength'],r['pistonVelocity']) for r in d['pistonCrossing']}==set(itertools.product([.1,.05],[-1,1])),'piston crossing tree')
    for r in d['pistonCrossing']:require(r['gridCrossings']>=3 and abs(r['relativeMassChange'])<1e-10 and abs(r['energyBudgetResidual'])<1e-8 and max(abs(v) for v in r['momentumBudgetResidual'])<1e-9 and r['minimumPressure']>0,'crossing gas/wall budgets')
    env=json.loads((root/'environment.json').read_text());require(env['workingTreeDirty'] is False,'clean packet producer');require(env['corePin']=={'version':'0.1.0-alpha.14','revision':'f5543e3c336a80ec86868c3f0f245b688dfba148'},'exact alpha.14 packet dependency')
    return {'schemaVersion':1,'status':'passed','candidate':env['candidate'],'movingHistories':32,'movingIntervals':moving_intervals,'movingFrameCells':moving_cells,'remapHistories':2,'remapFrameCells':remap_cells,'dryToWet':opened,'wetToDry':closed,'completeReports':'byte-identical','scope':'complete native remap replay and moving-reservoir intervals; complete public geometry/sealed/crossing records; wall/piston benchmark verified separately'}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();d=verify(a.root);(a.root/'packet-verification.json').write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS complete packet adoption native fields and independent reservoir/wall/remap budgets;',d['movingFrameCells'],'moving cells')
