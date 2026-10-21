"""Existing Beirut field variants through the declared quantized wall/roof proxy model."""
import csv,hashlib,json,math,os,subprocess,time
from pathlib import Path
import numpy as np
repo=Path.cwd();root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-product-portability-v4');root.mkdir(exist_ok=False)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def save():(root/'study.json').write_text(json.dumps(report,indent=2)+'\n')
recorded=Path('/Volumes/StudioData/bombcad/ml/judge/compare-first/beirut-p0-1')
strips=Path('/Volumes/StudioData/bombcad/ml/judge/strips/beirut-p0-1.csv');prior=Path('/Volumes/StudioData/bombcad/ml/judge/fpw/peaks/beirut-p0-1.csv')
folders={'default':recorded/'field','full':Path('/private/tmp/bombcad-production-phase/beirut-p0-1-full')}
for mode in ['fast-on','fast-off','safe-on','safe-off']:folders[mode]=Path('/private/tmp/bombcad-explicit-math')/(mode+'-tiled')
folders['cuda']=Path('/Volumes/StudioData/bombcad/cuda-dataset-backend/field-batch/beirut-p0-1-1792566332868976000/result/dataset')
exe=Path('.build/release/scenebench').resolve()
sources=[*sorted((repo/'Sources/BlastModel').rglob('*.swift')),repo/'Sources/SceneBench/FieldWalls.swift',repo/'Scripts/ml/judge_field.py']
pins={str(p):digest(p) for p in [exe,Path(__file__),strips,prior,*sources,*[recorded/'loads'/n for n in ['strips.json','net.f16','components.json','components.f16']]]}
for folder in folders.values():
 for name in ['inputs.npy','mask.npy','targets.npy','meta.json']:pins[str(folder/name)]=digest(folder/name)
meta=json.loads((recorded/'field/meta.json').read_text());args=meta['arguments'][:];i=args.index('--out');del args[i:i+2]
for flag in ['--osm','--dem','--heights']:pins[args[args.index(flag)+1]]=digest(args[args.index(flag)+1])
mask=np.load(recorded/'field/mask.npy').astype(bool);arrays={name:np.load(folder/'targets.npy') for name,folder in folders.items()}
mask &= (arrays['default'][0]>10)&(arrays['default'][2]>1e-3) # Existing judge_field/train_field sampling filter only; dataset masks stay unchanged.
for name,folder in folders.items():
 assert arrays[name].shape==arrays['default'].shape and np.isfinite(arrays[name]).all()
 for file in ['inputs.npy','mask.npy']:assert digest(folder/file)==digest(recorded/'field'/file)
report=dict(status='running',scope=__doc__,revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),worktreeDirty=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),pinsSHA256=pins,fieldFolders={k:str(v) for k,v in folders.items()},sampling='Existing judged ground-floor strips; same front-cell selection and mask as judge_field.py; mean field peak/first phase, surrogate rise. Roof loads are ground-floor-ratio proxies only.',draws=50,factors=[1,1.3],scales=[0,.5,1],productPulseQuantum=.03)
save()
def box(row):return (int(float(row['axis'])),int(float(row['outward'])))+tuple(round(float(row[k])*10) for k in ['x0','y0','z0','x1','y1','z1'])
def cells(s):
 axis,outward=int(s['axis']),int(s['outward']);low=[s['x0'],s['y0']];high=[s['x1'],s['y1']];dx=meta['cellSizeM'];face=high[axis] if outward>0 else low[axis]
 across=math.ceil(face/dx-.5)-(outward<0);other=1-axis;a=math.ceil(low[other]/dx-.5);b=math.ceil(high[other]/dx-.5)-1
 if b<a:a=b=math.floor((low[other]+high[other])*.5/dx)
 along=np.arange(a,b+1);constant=np.full_like(along,across);r,c=(along,constant) if axis==0 else (constant,along)
 keep=(r>=0)&(r<mask.shape[0])&(c>=0)&(c<mask.shape[1]);r,c=r[keep],c[keep];keep=mask[r,c];return r[keep],c[keep]
with strips.open() as f:all_strips={box(row):{k:float(v) for k,v in row.items()} for row in csv.DictReader(f)}
with prior.open() as f:previous=list(csv.DictReader(f))
assert len({box(row) for row in previous})==len(previous)
names=list(arrays)+['repeat'];header=['axis','outward','x0','y0','z0','x1','y1','z1']+[q+':'+name for name in names for q in ['peak','impulse']]
loads={name:[] for name in names};baseline_delta=[0.,0.];coverage={name:{str(c):set() for c in [0,2]} for name in arrays}
published_peak=np.exp(np.log(np.maximum(arrays['default'][0],1e-6)).astype(np.float32));published_mismatches=[0,0]
with (root/'peaks.csv').open('w') as f:
 writer=csv.writer(f);writer.writerow(header)
 for row in previous:
  s=all_strips[box(row)];r,c=cells(s);assert len(r)>0
  values={name:(float(a[0,r,c].mean()),float(a[2,r,c].mean())) for name,a in arrays.items()};values['repeat']=values['default']
  assert all(p>0 and i>0 for p,i in values.values())
  published=[float(published_peak[r,c].mean()),values['default'][1]]
  for channel,key in enumerate(['peak:runField','impulse:runFieldFirst']):
   baseline_delta[channel]=max(baseline_delta[channel],abs(values['default'][channel]-float(row[key]))/max(1e-30,abs(float(row[key]))))
   published_mismatches[channel]+=float(format(published[channel],'.6g'))!=float(row[key])
  writer.writerow([row[k] for k in header[:8]]+[v for name in names for v in values[name]])
  for name in names:loads[name].append(values[name])
  for name,a in arrays.items():
   for channel in [0,2]:
    errors=np.abs(a[channel,r,c]-arrays['default'][channel,r,c]);bad=errors>(.05+.002*np.abs(arrays['default'][channel,r,c]))
    coverage[name][str(channel)].update((r[bad]*mask.shape[1]+c[bad]).tolist())
assert published_mismatches==[0,0],('Published log/exp and six-significant-digit CSV path differs',published_mismatches)
report['baselineSamplingMaxRelativeDifferenceFromPublishedCSV']=baseline_delta;report['publishedSamplingPipelineMismatches']=published_mismatches;report['strips']=len(previous)
report['loadDifferences']={}
for name in arrays:
 a=np.array(loads['default']);b=np.array(loads[name]);quant=lambda v:np.copysign(np.floor(np.abs(np.log(v)/math.log(1.03))+.5),np.log(v))
 report['loadDifferences'][name]=dict(maxAbsolute=np.abs(b-a).max(axis=0).tolist(),maxRelative=(np.abs(b-a)/a).max(axis=0).tolist(),stripsWithDifferentRoundedPeak=int((quant(a[:,0])!=quant(b[:,0])).sum()),stripsWithDifferentRoundedImpulse=int((quant(a[:,1])!=quant(b[:,1])).sum()),failedFieldReceiversSampled={k:sorted(v) for k,v in coverage[name].items()})
variants=['default:default','repeat:repeat']
for name in arrays:
 if name!='default':variants.extend([name+':default','default:'+name,name+':'+name])
command=['/Users/louisemmett/.local/bin/gpu-slot','--mem','3',str(exe),'field-walls',*args,'--loads',str(recorded/'loads'),'--peaks',str(root/'peaks.csv'),'--variants',','.join(variants),'--factors','1,1.3','--scales','0,0.5,1','--draws','50','--out',str(root/'judged.json')]
report['command']=command;report['variants']=variants;save()
with (root/'judge.log').open('w') as f:
 p=subprocess.Popen(command,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
 report['process']=dict(pid=p.pid,pgid=p.pid);save();code=p.wait()
report['returncode']=code
if code:report['status']='failed';save();raise RuntimeError('field-walls failed; inspect same process and log')
for name,h in pins.items():assert digest(name)==h,('source/input changed',name)
judged=json.loads((root/'judged.json').read_text());metrics=['wallsModerate','wallsHeavy','roofModerate'];changes={}
for v in variants:
 changes[v]={}
 for metric in metrics:
  pairs=[]
  for index,pair in enumerate(judged['grid']):
   diffs=[];locations=[]
   for b in judged['buildings']:
    if metric=='roofModerate' and b['roof'] is None:continue
    if metric!='roofModerate' and b['wall'] is None:continue
    base=b[metric]['default:default'][index];other=b[metric][v][index]
    assert b[metric]['repeat:repeat'][index]==base
    diffs.append(other-base)
    if base!=other:locations.append(dict(object=b['object'],reference=base,candidate=other))
   pairs.append(dict(pair=pair,buildings=len(diffs),changed=len(locations),maxAbsolute=max(map(abs,diffs),default=0),meanAbsolute=float(np.mean(np.abs(diffs))) if diffs else 0,locations=locations))
  changes[v][metric]=pairs
report['productChanges']=changes;report['buildings']=len(judged['buildings']);report['status']='complete';save()
print('Complete',report['strips'],'strips',report['buildings'],'buildings',len(variants),'variants',flush=True)
for v,metrics in changes.items():print(v,{m:[p['changed'] for p in ps] for m,ps in metrics.items()},flush=True)
