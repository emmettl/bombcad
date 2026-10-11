#!/usr/bin/env python3
"""Independent half-space vertex enumeration for selected box/cell gas moments."""
import argparse,copy,importlib.util,itertools,json,math,sys
from pathlib import Path
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pressure_reference',ROOT/'Scripts/verify-qr-pressure-loads.py');pressure=importlib.util.module_from_spec(spec);spec.loader.exec_module(pressure)
reader=pressure.reader;need=reader.need;dot=pressure.dot;cross=pressure.cross;EPS=2**-52;CACHE={}
def norm(v):return math.sqrt(dot(v,v))
def determinant(a,b,c):return dot(a,cross(b,c))
def cell_reference(lower,h,position,R):
    centre=[v+h/2 for v in lower];corners=list(itertools.product([-h/2,h/2],repeat=3))
    cube=[]
    for axis in range(3):
        for sign in [-1,1]:
            n=[float(sign) if i==axis else 0. for i in range(3)];cube.append((n,h/2))
    box=[]
    for axis in range(3):
        for sign in [-1,1]:
            n=[sign*R[i][axis] for i in range(3)];box.append((n,.4+dot(n,[p-c for p,c in zip(position,centre)])))
    full=h**3;second=[[full*h*h/12 if i==j else 0. for j in range(3)] for i in range(3)]
    planes=cube+box;condition=1.
    if any(all(dot(n,p)>d for p in corners) for n,d in box):return {'volume':full,'first':[0.]*3,'second':second,'centre':centre,'errorBudget':1024*EPS*full,'condition':condition,'kind':'outside'}
    if all(all(dot(n,p)<=d for n,d in box) for p in corners):return {'volume':0.,'first':[0.]*3,'second':[[0.]*3 for _ in range(3)],'centre':centre,'errorBudget':1024*EPS*full,'condition':condition,'kind':'inside'}
    vertices=[]
    for selected in itertools.combinations(planes,3):
        (a,da),(b,db),(c,dc)=selected;det=determinant(a,b,c)
        if abs(det)<128*EPS:continue  # Exact parallel/opposite constraint families.
        bc=cross(b,c);ca=cross(c,a);ab=cross(a,b)
        inverse_norm=max(math.fsum(abs(col[i]/det) for col in [bc,ca,ab]) for i in range(3))
        need(inverse_norm<1e4,'supported independently solved vertex conditioning')
        p=[(da*bc[i]+db*ca[i]+dc*ab[i])/det for i in range(3)]
        if any(dot(n,p)-d > 512*EPS*max(h,abs(d)) for n,d in planes):continue
        condition=max(condition,inverse_norm)
        if any(norm([a-b for a,b in zip(p,v)])<1024*EPS*h*inverse_norm for v in vertices):continue
        vertices.append(p)
    if len(vertices)<4:
        return {'volume':full,'first':[0.]*3,'second':second,'centre':centre,'errorBudget':1024*EPS*(1+condition)*full,'condition':condition,'kind':'emptyIntersection','solidVertices':len(vertices)}
    origin=[math.fsum(v[i] for v in vertices)/len(vertices) for i in range(3)];volumes=[];first=[];seconds=[];faces=set()
    for n,d in planes:
        ids=tuple(i for i,v in enumerate(vertices) if abs(dot(n,v)-d)<=1024*EPS*max(h,abs(d))*condition)
        if len(ids)<3 or ids in faces:continue
        faces.add(ids);points=[vertices[i] for i in ids];mid=[math.fsum(v[i] for v in points)/len(points) for i in range(3)]
        axis=min(range(3),key=lambda i:abs(n[i]));unit=[float(i==axis) for i in range(3)];a=cross(n,unit);length=norm(a);a=[v/length for v in a];b=cross(n,a)
        points.sort(key=lambda p:math.atan2(dot([v-c for v,c in zip(p,mid)],b),dot([v-c for v,c in zip(p,mid)],a)))
        for p,q in zip(points,points[1:]+points[:1]):
            tetra=[origin,mid,p,q];V=abs(determinant([v-c for v,c in zip(mid,origin)],[v-c for v,c in zip(p,origin)],[v-c for v,c in zip(q,origin)]))/6
            sums=[math.fsum(v[i] for v in tetra) for i in range(3)];volumes.append(V);first.append([V*v/4 for v in sums])
            seconds.append([[V*(sums[i]*sums[j]+math.fsum(v[i]*v[j] for v in tetra))/20 for j in range(3)] for i in range(3)])
    solid=math.fsum(volumes);error=1024*EPS*(1+condition)*full
    need(-error<=solid<=full+error,'independent solid intersection capacity')
    gas=full-solid
    if abs(gas)<error:gas=0.  # Selected capacity comparison retains this rounding budget.
    return {'volume':gas,'first':[-math.fsum(v[i] for v in first) for i in range(3)],
            'second':[[second[i][j]-math.fsum(v[i][j] for v in seconds) for j in range(3)] for i in range(3)],
            'centre':centre,'errorBudget':error,'condition':condition,'kind':'cut','solidVertices':len(vertices)}
def grid(h,position,angle):
    key=(h,tuple(position),angle)
    if key not in CACHE:
        n=round(2/h);R=pressure.rotation(angle);CACHE[key]=[cell_reference([h*x,h*y,h*z],h,position,R) for z in range(n) for y in range(n) for x in range(n)]
    return CACHE[key]
def close(a,b,error,scale,label):
    need(math.isfinite(a) and math.isfinite(b) and abs(a-b)<=error+512*EPS*max(abs(a),abs(b),abs(scale),1e-300),label+': '+str(a)+' != '+str(b))
def group_reference(plan,group,cells,centre):
    members=plan['members'][group];V=math.fsum(cells[n]['volume'] for n in members);error=math.fsum(cells[n]['errorBudget'] for n in members)
    first=[];second=[];extent=0.
    for n in members:
        c=cells[n];d=[x-y for x,y in zip(c['centre'],centre)];extent=max(extent,norm(d))
        first.append([c['first'][i]+c['volume']*d[i] for i in range(3)])
        second.append([[c['second'][i][j]+c['first'][i]*d[j]+d[i]*c['first'][j]+c['volume']*d[i]*d[j] for j in range(3)] for i in range(3)])
    return V,[math.fsum(v[i] for v in first) for i in range(3)],[[math.fsum(v[i][j] for v in second) for j in range(3)] for i in range(3)],error,extent

def check_plan(plan,body,angle,h):
    records=[]
    for final in [False,True]:
        position=[p+(plan['duration']*v if final else 0.) for p,v in zip(body['position'],plan['velocity'])];cells=grid(h,position,angle)
        if final:
            need(len(cells)==len(plan['memberFinalVolumes']),'complete final member capacity tree')
            for n,(r,V) in enumerate(zip(cells,plan['memberFinalVolumes'])):close(V,r['volume'],r['errorBudget'],h**3,'independent final cut-cell capacity '+str(n))
        geometry=plan['finalConservedGeometry' if final else 'oldConservedGeometry'];centres=plan['finalCentres' if final else 'oldCentres']
        for group,centre in enumerate(centres):
            V,first,second,error,extent=group_reference(plan,group,cells,centre)
            volume=plan['finalVolumes'][group] if final else plan['cells'][group]['volume']
            close(volume,V,error,h**3*len(plan['members'][group]),'independent grouped cut-cell volume')
            length=h+extent
            for f in first:close(f,0.,error*length,V*length,'independent grouped gas centroid')
            if geometry is not None:
                for i in range(3):
                    for j in range(3):close(geometry['covariance'][group][i][j]*V,second[i][j],error*length*length,V*length*length,'independent grouped gas covariance')
        records.append({'final':final,'cells':len(cells),'groups':len(centres),'cutCells':sum(r['kind']=='cut' for r in cells),'maximumVertexCondition':max(r['condition'] for r in cells),'maximumAbsoluteCapacityBudget':max(r['errorBudget'] for r in cells)})
    return records

def check_volume_samples(event,row):
    plan=event['plan'];h=event['h'];cells=grid(h,row['bodyCentre'],row['rotation']);findings=[]
    for group,sample in event['samples'].items():
        V,first,second,error,extent=group_reference(plan,group,cells,sample['centre']);length=h+extent
        close(plan['cells'][group]['volume'],V,error,h**3*len(plan['members'][group]),'independent pressure-sample group volume')
        for f in first:close(f,0.,error*length,V*length,'independent pressure-sample centroid')
        for i in range(3):
            for j in range(3):close(sample['covariance'][i][j]*V,second[i][j],error*length*length,V*length*length,'independent pressure-sample covariance')
        findings.append({'group':group,'volume':V,'capacityBudget':error,'momentLengthScale':length})
    return findings

def verify(path):
    rows=[];controls=[]
    for raw in reader.iter_cases(path):
        if raw['id'].startswith('reflection-'):continue
        c=reader.decode(raw);checks=[]
        if c['id'].startswith('uniform-'):
            checks=check_plan(c['result']['plan'],c['result']['body'],c['parameters']['angle'],c['parameters']['cellSize'])
            if c['id']=='uniform-0.23-euler':
                for label in ['paired-capacity','zero-sum-covariance']:
                    changed=copy.deepcopy(c);plan=changed['result']['plan']
                    if label=='paired-capacity':plan['memberFinalVolumes'][0]+=.00001;plan['memberFinalVolumes'][1]-=.00001
                    else:plan['oldConservedGeometry']['covariance'][0][0][0]+=.00001;plan['oldConservedGeometry']['covariance'][1][0][0]-=.00001
                    try:check_plan(plan,changed['result']['body'],changed['parameters']['angle'],changed['parameters']['cellSize'])
                    except ValueError:controls.append({'id':label,'rejected':True});continue
                    raise ValueError('Cut-cell corruption escaped '+label)
        elif c['id']=='moving-pulse':
            for e in c['events']:
                if e['kind']=='trajectory-step':checks+=check_plan(e['plan'],e['body'],c['parameters']['angle'],c['parameters']['cellSize'])
        else:
            need(c['id'].startswith('initial-wall-'),'declared geometry case')
            for e in c['events']:
                if e['kind']=='volume-pressure-fits':checks.append({'samples':check_volume_samples(e,c['result'][0]),'rings':e['rings']})
        rows.append({'id':c['id'],'checks':checks});print('PASS independent cut-cell/group moments',c['id'],flush=True)
    need(len(rows)==8 and len(controls)==2,'complete selected cut-cell reference/control tree')
    return {'schemaVersion':1,'status':'passed','cases':rows,'controls':controls,'scope':'independent twelve-half-space vertex enumeration and analytic solid simplex moments subtracted from cell integrals; selected final capacities, old/final group moments and all retained pressure-sample moments; declared conditioning-aware rounding budgets, no universal clipping or empirical certificate'}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('report',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args();d=verify(a.report);a.output.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n')
