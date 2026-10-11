#!/usr/bin/env python3
"""Independent closed-domain geometric integral references for selected native moving histories."""
import argparse,copy,importlib.util,json,math,sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('coupled_native_reader',ROOT/'Scripts/verify-qr-coupled-output.py');reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
need=reader.need

def close(a,b,scale,label):reader.ref.near(a,b,scale,label)
def check(plan,body,angle):
    need(body['mass']==2 and body['size']==[.8,.8,.8] and body['centreOfMass']==[0.,0.,0.], 'declared centred uniform rigid cube')
    q=body['orientation']['vector'];expected=[math.sin(angle/2)*v/math.sqrt(14) for v in [1,2,3]]+[math.cos(angle/2)]
    for a,b in zip(q,expected):close(a,b,1.,'declared native rotation')
    x,y,z,w=q
    R=[[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
       [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
       [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]]
    flat=[member for group in plan['members'] for member in group]
    need(len(flat)==len(set(flat)) and len(plan['cells'])==len(plan['members']), 'unique complete group member support')
    need({n for n,V in enumerate(plan['memberFinalVolumes']) if V>0} <= set(flat), 'complete occupied final support')
    for group,members in enumerate(plan['members']):
        need(bool(members) and all(plan['cellToGroup'][n]==group for n in members), 'actual cell/group partition identity')
        V=math.fsum(plan['memberFinalVolumes'][n] for n in members)
        close(V,plan['finalVolumes'][group],V,'group/member geometric final capacity')
    solid=.8**3;diagonal=.8**2/12
    for final in [False,True]:
        geometry=plan['finalConservedGeometry' if final else 'oldConservedGeometry'];need(geometry is not None,'actual endpoint conserved geometry')
        centre=[p+(plan['duration']*v if final else 0) for p,v in zip(body['position'],plan['velocity'])]
        for axis in range(3):
            extent=.4*math.fsum(abs(R[axis][j]) for j in range(3))
            need(centre[axis]-extent>0 and centre[axis]+extent<2,'strict closed-domain body containment')
        volumes=plan['finalVolumes'] if final else [c['volume'] for c in plan['cells']]
        means=geometry['centres'];cov=geometry['covariance']
        need(len(volumes)==len(means)==len(cov)==len(geometry['volumePoints']),'complete endpoint moment tree')
        need(means==plan['finalCentres' if final else 'oldCentres'],'actual geometry/plan centroid linkage')
        total=math.fsum(volumes);close(total,8-solid,8.,'independent cube-complement gas volume')
        for i in range(3):
            first=math.fsum(V*c[i] for V,c in zip(volumes,means));close(first,8-solid*centre[i],8.,'independent complete first volume moment')
            for j in range(3):
                terms=[V*(C[i][j]+c[i]*c[j]) for V,C,c in zip(volumes,cov,means)]
                # A rotated uniform cube has isotropic covariance s^2/12. These
                # closed integrals use no clipping or tetrahedral production code.
                domain=32/3 if i==j else 8.
                expected=domain-solid*(centre[i]*centre[j]+(diagonal if i==j else 0.))
                close(math.fsum(terms),expected,math.fsum(abs(v) for v in terms)+abs(domain),'independent complete second volume moment')
    walls=[b['geometry'] for b in plan['boundaries'] if b['geometry']['owner']==1]
    close(math.fsum(b['area'] for b in walls),6*.8**2,6*.8**2,'independent complete translating body surface area')
    normals=[[sign*R[i][j] for i in range(3)] for j in range(3) for sign in [-1,1]]
    for b in walls:need(any(max(abs(a-c) for a,c in zip(b['normal'],n))<256*2**-52 for n in normals),'rotated native cube-face normal')
    for i in range(3):
        terms=[b['area']*b['normal'][i] for b in walls];close(math.fsum(terms),0.,math.fsum(map(abs,terms)),'closed moving surface normal integral')
        for j in range(3):
            terms=[b['area']*b['normal'][i]*b['centroid'][j] for b in walls]
            close(math.fsum(terms),-solid if i==j else 0.,math.fsum(map(abs,terms)),'independent moving surface divergence moment')
    return len(volumes)

def verify(path):
    rows=[]
    for raw in reader.iter_cases(path):
        if not raw['id'].startswith('uniform-') and raw['id']!='moving-pulse':continue
        c=reader.decode(raw);count=0
        if c['id'].startswith('uniform-'):count+=check(c['result']['plan'],c['result']['body'],c['parameters']['angle'])
        else:
            for e in c['events']:
                if e['kind']=='trajectory-step':count+=check(e['plan'],e['body'],c['parameters']['angle'])
        rows.append({'id':c['id'],'groupMomentsChecked':count,'endpointCount':2*(1 if c['id'].startswith('uniform-') else c['result'][0]['frames'][-1]['steps'])})
        print('PASS independent complete-domain geometry moments',c['id'],flush=True)
    need(len(rows)==5 and sum(r['endpointCount'] for r in rows)==16,'complete selected moving geometry cohort')
    # Targeted coherent changes retain a valid decoded native structure; the
    # independent closed integrals must reject both volume and covariance errors.
    first=reader.decode(next(reader.iter_cases(path)));controls=[]
    for label in ['capacity','covariance','wall-moment']:
        c=copy.deepcopy(first);p=c['result']['plan']
        if label=='capacity':p['cells'][0]['volume']*=1.01
        elif label=='covariance':p['oldConservedGeometry']['covariance'][0][0][0]+=.01
        else:
            b=next(b for b in p['boundaries'] if b['geometry']['owner']==1);b['geometry']['centroid'][0]+=.1
        try:check(p,c['result']['body'],c['parameters']['angle'])
        except ValueError:controls.append({'id':label,'rejected':True});continue
        raise ValueError('Geometry corruption escaped '+label)
    return {'schemaVersion':1,'status':'passed','cases':rows,'controls':controls,'scope':'independent complete-domain cube-complement volume/first/second moments, partition/capacity and closed translating surface area/normal/divergence integrals; not a per-cut-cell clipping or empirical accuracy proof'}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('report',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();d=verify(a.report);a.output.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
