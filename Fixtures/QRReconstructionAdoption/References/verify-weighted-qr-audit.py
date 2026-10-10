#!/usr/bin/env python3
"""Exact rational LS references over actual native matrices; rejected policies remain findings."""
import argparse,hashlib,json,math,struct
from fractions import Fraction as F
from pathlib import Path
EPS=2**-52
CACHE={}
def need(ok,msg):
 if not ok:raise ValueError(msg)
def scalar(v):
 need(set(v)=={'value','bits'},'scalar schema');bits=int(v['bits'],16);n=struct.unpack('>d',bits.to_bytes(8,'big'))[0];shown=float(v['value']);need((math.isnan(n) and math.isnan(shown)) or n==shown and (n!=0 or math.copysign(1,n)==math.copysign(1,shown)),'native scalar bits');return n
def vector(v):return [scalar(x) for x in v]
def matrix(v):return [vector(x) for x in v]
def expected_direct():
 result={}
 for width in [3,9]:
  base=[[float(i==j) if i<width else (((i-width+1)*(j+2))%7-3)/8 for j in range(width)] for i in range(width+3)];nominal=[(1 if j%2==0 else -1)*(j+1)/8 for j in range(width)]
  labels={'common':list(map(str,[-1000,-600,-500,-100,0,100,500,600,1000])),'column':list(map(str,[-1000,-600,-100,-40,-20,0,20,40,100,600,1000])),'near':['zero','-55','-45','-40','-35','-34','-33','-32','-20','-10'],'rank':['duplicate','zero'],'short':['short']}
  for family,values in labels.items():
   for label in values:
    rows=[row[:] for row in base]
    if family=='common':rows=[[v*2**int(label) for v in row] for row in rows]
    if family=='column':
     for row in rows:row[-1]*=2**int(label)
    if family=='near':
     delta=0 if label=='zero' else 2**int(label)
     for i,row in enumerate(rows):row[-1]=row[0]+delta*base[i][-1]
    if family=='rank':
     for row in rows:
      if label=='duplicate':row[-1]=row[0]
      else:row[:]=[0.0]*width
    if family=='short':rows=rows[:width-1]
    for reverse in [False,True]:
     for noisy in [False,True]:
      b=[sum(v*w for v,w in zip(row,nominal))+(((i*11)%7-3)/256*(2**int(label) if family=='common' else 1) if noisy else 0) for i,row in enumerate(rows)];a=list(reversed(rows)) if reverse else rows
      if reverse:b.reverse()
      id=f'direct/{width}/{family}/{label}/{str(reverse).lower()}/{str(noisy).lower()}'
      result[id]=(a,b,{'width':width,'family':family,'label':label,'reversed':reverse,'noisy':noisy})
  for kind in ['short-rhs','long-rhs','nan-rhs','inf-rhs']:
   rhs=[sum(v*w for v,w in zip(row,nominal)) for row in base]
   if kind=='short-rhs':rhs.pop()
   if kind=='long-rhs':rhs.append(99)
   if kind=='nan-rhs':rhs[0]=math.nan
   if kind=='inf-rhs':rhs[0]=math.inf
   result[f'dimensions/{width}/{kind}']=(base,rhs,{'width':width,'kind':kind})
 return result
def same(a,b):
 need(len(a)==len(b),'native dimensions')
 for x,y in zip(a,b):need(x==y or math.isnan(x) and math.isnan(y),'case/input identity')
def exact_factor(a):
 key=hashlib.sha256(json.dumps(a).encode()).hexdigest()
 if key in CACHE:return CACHE[key]
 if not a or not all(math.isfinite(v) for row in a for v in row):return None,None
 width=len(a[0]);cols=[[F.from_float(row[j]) for row in a] for j in range(width)];gram=[[sum(x*y for x,y in zip(cols[i],cols[j])) for j in range(width)] for i in range(width)]
 augmented=[row+[F(int(i==j)) for j in range(width)] for i,row in enumerate(gram)];at=0
 for col in range(width):
  pivot=next((i for i in range(at,width) if augmented[i][col]),None)
  if pivot is None:continue
  augmented[at],augmented[pivot]=augmented[pivot],augmented[at];value=augmented[at][col];augmented[at]=[v/value for v in augmented[at]]
  for i in range(width):
   if i!=at and augmented[i][col]:
    value=augmented[i][col];augmented[i]=[v-value*w for v,w in zip(augmented[i],augmented[at])]
  at+=1
 inverse=[row[width:] for row in augmented] if at==width else None;CACHE[key]=(at,(cols,inverse));return CACHE[key]
def near(a,b,scale,tolerance=2e-10):
 return a==b or math.isfinite(a) and math.isfinite(b) and abs(a-b)<=max(4*math.ulp(b),tolerance*scale)
def verify_record(row):
 a=matrix(row['rows']);b=vector(row['rhs']);need(not a or all(len(x)==len(a[0]) for x in a),'rectangular native matrix');width=len(a[0]) if a else 0
 rank,ref=exact_factor(a);classification=None;error=None;orthogonality=None;reconstruction=None
 if row['factorAccepted']:
  q=matrix(row['vectors']);upper=matrix(row['upper']);perm=row['permutation'];need(len(q)==len(upper)==width and sorted(perm)==list(range(width)) and all(len(x)==len(a) for x in q) and all(len(x)==width for x in upper),'complete QR factor dimensions')
  need(all(upper[k][k]>0 and math.isfinite(upper[k][k]) for k in range(width)) and all(upper[i][j]==0 for i in range(width) for j in range(i)),'triangular positive finite factor')
  scale=max(abs(v) for x in a for v in x)
  orthogonality=max(abs(sum(v*w for v,w in zip(q[i],q[j]))-float(i==j)) for i in range(width) for j in range(width))
  reconstruction=max(abs(sum(q[k][i]*upper[k][j] for k in range(width))-a[i][perm[j]])/scale for i in range(len(a)) for j in range(width))
  if len(b)!=len(a):classification='unchecked_rhs_dimension_accepted' if row['solveAccepted'] else 'rhs_dimension_rejected'
  elif not all(math.isfinite(v) for v in b):classification='nonfinite_rhs_rejected' if not row['solveAccepted'] else 'nonfinite_rhs_accepted'
  elif not row['solveAccepted']:classification='solve_representation_rejected'
  else:
   need(rank==width,'accepted exact-native rank failure');cols,inverse=ref;projected=[sum(v*F.from_float(w) for v,w in zip(col,b)) for col in cols];solution=[sum(v*w for v,w in zip(row,projected)) for row in inverse];coeff=vector(row['coefficients']);need(len(coeff)==width,'full coefficient output');pred=vector(row['predictions']);need(len(pred)==len(a),'full prediction output')
   for values,value in zip(a,pred):need(near(value,sum(v*w for v,w in zip(values,coeff)),max(1,abs(value)),64*EPS),'source diagnostic prediction')
   error=max(abs(v-float(w))/max(1,abs(float(w))) for v,w in zip(coeff,solution));classification='reference_agreement' if error<=2e-10 else 'finite_coefficient_inaccuracy'
 else:
  if rank is None:classification='nonfinite_native_matrix_rejected' if a else 'empty_rows_rejected'
  elif rank<width:classification='native_rank_rejected'
  else:
   norms=[sum(row[j]*row[j] for row in a) for j in range(width)];largest=max(norms)
   classification='unsafe_square_norm_scale_rejected' if not math.isfinite(largest) or largest==0 else 'relative_rank_policy_rejected'
 return {'id':row['id'],'rows':len(a),'columns':width,'exactNativeRank':rank,'classification':classification,'relativeCoefficientError':error,'orthogonalityDefect':orthogonality,'relativeReconstructionError':reconstruction}
def expected_geometry():
 d={}
 for origin in [0,1]:
  translation=[0,0,0] if origin==0 else [17,-8,31]
  for affine in [False,True]:
   samples=[]
   for z in [-1.1,0,.9]:
    for y in [-.7,0,1.3]:
     for x in [-1.3,0,.8]:samples.append(([translation[0]+x,translation[1]+y,translation[2]+z],len(samples)))
   cell=samples[13];neighbours=[v for i,v in enumerate(samples) if i!=13]
   for scale,label in [(.1,'0.1'),(.4,'0.4'),(2,'2.0'),(1e-100,'1e-100'),(1e100,'1e+100')]:
    for reverse in [False,True]:
     for quadratic in [False,True]:
      for aware in [False,True]:
       id=f'geometry/{origin}/{str(affine).lower()}/{label}/{str(reverse).lower()}/{str(quadratic).lower()}/{str(aware).lower()}'
       d[id]=(cell,list(reversed(neighbours)) if reverse else neighbours,scale,affine,quadratic,aware,{'origin':origin,'affine':affine,'scale':label,'reversed':reverse,'quadratic':quadratic,'aware':aware})
 axes=[[1,0,0],[0,1,0],[0,0,1],[-1,0,0],[0,-1,0],[0,0,-1]]
 for family in ['axes','planar','single','empty']:
  points=axes if family=='axes' else [p for p in axes if p[2]==0] if family=='planar' else axes[:1] if family=='single' else []
  for quadratic in [False,True]:
   for aware in [False,True]:d[f'fallback/{family}/{str(quadratic).lower()}/{str(aware).lower()}']=(([0,0,0],0),[(p,i+1) for i,p in enumerate(points)],1,True,quadratic,aware,{'family':family,'quadratic':quadratic,'aware':aware})
 return d
def verify_sample(record,spec,affine):
 point,index=spec;same(vector(record['centre']),point);cov=matrix(record['covariance']);diagonal=[.0064+.0001*index,.0169,.0036+.00002*index]
 need(cov==[[diagonal[i] if i==j else 0 for j in range(3)] for i in range(3)],'sample covariance identity')
 x,y,z=point
 expected=2+3*x-.7*y+1.1*z if affine else 1.2+2*x-3*y+.7*z+.9*(x*x+diagonal[0])-.4*(y*y+diagonal[1])+.3*(z*z+diagonal[2])+1.1*x*y-.6*x*z+.4*y*z
 need(near(scalar(record['average']),expected,max(1,abs(expected)),128*EPS),'independent polynomial volume-average input')
def verify_data(data):
 need(set(data)=={'schemaVersion','direct','geometry'} and data['schemaVersion']==1,'audit schema')
 expected=expected_direct();need(len(data['direct'])==len(expected) and {r['id'] for r in data['direct']}==set(expected),'complete direct case tree');results=[]
 for row in data['direct']:
  a,b,params=expected[row['id']];need(row['parameters']==params,'direct case parameters');actual=matrix(row['rows']);need(len(actual)==len(a),'direct row count')
  for x,y in zip(actual,a):same(x,y)
  same(vector(row['rhs']),b);results.append(verify_record(row))
 specs=expected_geometry();need(len(data['geometry'])==176 and {r['id'] for r in data['geometry']}==set(specs),'complete actual geometry case tree')
 geometry=[]
 for row in data['geometry']:
  cellSpec,nearby,scaleSpec,affine,quadratic,aware,parameters=specs[row['id']];need(row['parameters']==parameters and row['quadratic']==quadratic and row['volumeAware']==aware and scalar(row['scale'])==scaleSpec,'geometry parameter identity');verify_sample(row['cell'],cellSpec,affine);need(len(row['neighbours'])==len(nearby),'neighbour identity')
  for sample,spec in zip(row['neighbours'],nearby):verify_sample(sample,spec,affine)
  scale=scalar(row['scale']);cell=row['cell'];centre=vector(cell['centre']);cov=matrix(cell['covariance']);weights=[];weighted=[]
  for neighbour in row['neighbours']:
   point=vector(neighbour['centre']);difference=[p-c for p,c in zip(point,centre)];d=[v/scale for v in difference];w=scale/math.hypot(*difference);weights.append(w);nc=matrix(neighbour['covariance']);c=[[((nc[i][j]-cov[i][j])/(scale*scale) if row['volumeAware'] else 0) for j in range(3)] for i in range(3)];terms=d+[(d[0]*d[0]+c[0][0])/2,(d[1]*d[1]+c[1][1])/2,(d[2]*d[2]+c[2][2])/2,d[0]*d[1]+c[0][1],d[0]*d[2]+c[0][2],d[1]*d[2]+c[1][2]];weighted.append([v*w for v in terms])
  aw=vector(row['weights']);need(len(aw)==len(weights),'actual distance weights')
  for a,b in zip(aw,weights):need(near(a,b,max(abs(b),math.ulp(0.0)),128*EPS),'independent distance weight')
  actual=matrix(row['rows']);need(len(actual)==len(weighted),'actual weighted row count')
  for a,b in zip(actual,weighted):
   need(len(a)==len(b)==9,'basis width')
   for v,w in zip(a,b):need(near(v,w,max(abs(w),1e-300),256*EPS),'independent actual volume-aware weighted basis')
  rhs=vector(row['rhs']);mean=scalar(cell['average']);need(len(rhs)==len(row['neighbours']),'weighted rhs count')
  for v,neighbour,w in zip(rhs,row['neighbours'],aw):need(near(v,(scalar(neighbour['average'])-mean)*w,max(abs(v),1e-300),64*EPS),'actual weighted differences')
  stages=[]
  for key,width in [('quadraticFactor',9),('linearFactor',3)]:
   factor=row[key];same(vector(factor['rhs']),rhs);fa=matrix(factor['rows']);need(len(fa)==len(actual),'factor row bindings')
   for x,y in zip(fa,actual):same(x,y[:width])
   finding=verify_record(factor);finding['id']=row['id']+'/'+key;results.append(finding);stages.append(factor)
  selected=stages[0] if row['quadratic'] and stages[0].get('solveAccepted',False) else stages[1] if stages[1].get('solveAccepted',False) else None;coeff=vector(row['coefficients']);expected_coeff=[] if selected is None else vector(selected['coefficients']);same(coeff,expected_coeff);need(row['degree']==(2 if len(coeff)==9 else 1 if len(coeff)==3 else 0),'actual degree fallback')
  queries=[centre,[centre[i]+v for i,v in enumerate([.13,-.27,.08])],[centre[i]+v for i,v in enumerate([-.3,.4,-.2])]];need(len(row['queries'])==3,'complete query coverage')
  for query,point in zip(row['queries'],queries):
   p=vector(query['point']);same(p,point);d=[(p[i]-centre[i])/scale for i in range(3)];c=[[-cov[i][j]/(scale*scale) if row['volumeAware'] else 0 for j in range(3)] for i in range(3)];terms=d+[(d[0]*d[0]+c[0][0])/2,(d[1]*d[1]+c[1][1])/2,(d[2]*d[2]+c[2][2])/2,d[0]*d[1]+c[0][1],d[0]*d[2]+c[0][2],d[1]*d[2]+c[1][2]];value=mean+sum(v*w for v,w in zip(coeff,terms));need(near(scalar(query['value']),value,max(1,abs(value)),256*EPS),'actual query/mean restoration')
  geometry.append({'id':row['id'],'degree':row['degree']})
 counts={k:sum(r['classification']==k for r in results) for k in sorted({r['classification'] for r in results})};summary={'schemaVersion':1,'directCases':272,'actualStencilCases':176,'factorRecords':len(results),'classifications':counts,'factorOrthogonalityFindings':sum(r['orthogonalityDefect'] is not None and r['orthogonalityDefect']>2e-10 for r in results),'factorReconstructionFindings':sum(r['relativeReconstructionError'] is not None and r['relativeReconstructionError']>2e-10 for r in results),'findings':results,'geometry':geometry,'diagnosticBound':'2e-10 * max(1, abs(exact-native coefficient)); findings are not accepted generic solver contracts','newProductOrMigration':False}
 return summary
def verify_provenance(root):
 root=Path(root);metadata=json.loads((root/'environment.json').read_text());manifest=json.loads((root/'source/source.json').read_text());bindings=json.loads((root/'bindings.json').read_text())
 need(metadata['schemaVersion']==1 and metadata['workingTreeDirty'] is False and metadata['flags']==['-O','-warnings-as-errors'] and len(metadata['producerRevision'])==40,'committed optimized producer provenance')
 need(manifest['revision']=='5f2e50dcef5a5adcde3d3c4cb811426e6de2fe6c' and manifest['repository']=='https://github.com/emmettl/bombcad','BombCAD source pin')
 expected={
 'Sources/BlastCore/FiniteVolumePressureFit.swift':('31e58a31f681d81b8379fc7e81a000f75ba8df8d','8120e41b29cd28d68c731a96b637bd8db56f6b08c3871241a3f51e5c9c95f7f2','FiniteVolumePressureFit.swift.txt'),
 'Sources/BlastCore/ConservedGasReconstruction.swift':('3e2b5dffd343f26dd0957ac76fdbe3841fcc444a','55ccef8419142735965d7b19b7f961f903546f3bc1d4a0684893b6fd6df59d72','ConservedGasReconstruction.swift.txt'),
 'Tests/BlastCoreTests/FiniteVolumePressureFitTests.swift':('12edbd8f5298a3a77d0a0a471e69d9229d2e6e52','ca1fbf9ea3afe5db2823d1e07aa90ce6bbc737b51df885daf11c50225375fddb','FiniteVolumePressureFitTests.swift.txt')}
 need(set(manifest['sources'])==set(expected),'complete source inventory')
 for path,(blob,sha,snapshot) in expected.items():
  entry=manifest['sources'][path];raw=(root/'source'/snapshot).read_bytes();need(entry=={'gitBlob':blob,'sha256':sha,'snapshot':snapshot} and hashlib.sha256(raw).hexdigest()==sha and hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()==blob,'protected source identity')
 files={f'Fixtures/WeightedQRAudit/{p.name}':p for p in (root/'source').iterdir() if p.is_file()};files.update({f'Scripts/{p.name}':p for p in (root/'scripts').iterdir() if p.is_file()})
 need(set(files)==set(metadata['sourceHashes']),'complete recorded fixture/script identities')
 for path,file in files.items():need(hashlib.sha256(file.read_bytes()).hexdigest()==metadata['sourceHashes'][path],'recorded source hash')
 raw=(root/'source/FiniteVolumePressureFit.swift.txt').read_text();text=raw
 pairs=[('    private struct QR {','    struct QR {','fixture-only private QR visibility')]
 anchor='            let weighted = rows.enumerated().map { n, row in row.map { $0 * distanceWeights[n] } }';pairs.append((anchor,anchor+'\n            QRAuditHook.rows = weighted\n            QRAuditHook.weights = distanceWeights','capture actual weighted rows'))
 anchor='            let rhs = zip(neighbourAverages, weights).map { ($0.0 - average) * $0.1 }';pairs.append((anchor,anchor+'\n            QRAuditHook.rhs = rhs','capture actual weighted RHS'))
 need(bindings['schemaVersion']==1 and bindings['originalSHA256']==expected['Sources/BlastCore/FiniteVolumePressureFit.swift'][1] and bindings['patches']==[{'original':a,'traced':b,'label':c} for a,b,c in pairs],'bounded visibility/observation bindings')
 for a,b,_ in pairs:need(text.count(a)==1,'unique source hook');text=text.replace(a,b)
 text='enum QRAuditHook {\n    nonisolated(unsafe) static var rows: [[Double]] = []\n    nonisolated(unsafe) static var weights: [Double] = []\n    nonisolated(unsafe) static var rhs: [Double] = []\n}\n'+text
 compiled=(root/'compiled-original.swift').read_bytes();need(compiled==text.encode() and hashlib.sha256(compiled).hexdigest()==bindings['compiledSHA256'],'verbatim protected arithmetic compiled source')
 print('PASS source pins, complete producer hashes and reversible observation bindings')
def verify(root):
 root=Path(root);verify_provenance(root);summary=verify_data(json.loads((root/'original.json').read_text()));(root/'audit.json').write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n');print('PASS complete weighted QR source audit:',summary['classifications'])
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();verify(a.root)
