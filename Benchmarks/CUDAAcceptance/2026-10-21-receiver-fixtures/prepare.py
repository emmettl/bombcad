"""Predeclare fixtures and sample actual rejected receiver pairs; no response-based tuning."""
import hashlib,json
from pathlib import Path
import numpy as np
repo=Path.cwd();root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-receiver-fixtures');root.mkdir(exist_ok=False)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
product=json.loads((repo/'Benchmarks/CUDAAcceptance/2026-10-21-product-portability/study.json').read_text())
groups={'beirut':{k:Path(v) for k,v in product['fieldFolders'].items()}}
prior=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-independent-portability/terrain-h200-dx4')
groups['terrain']={'default':prior/'plain-reference','full':prior/'default-full','cuda':prior/'cuda-result/dataset'}
for mode in ['fast-on','fast-off','safe-on','safe-off']:groups['terrain'][mode]=prior/(mode+'-tiled')
loads=[];points=[];pins={};source_pairs={}
for case,folders in groups.items():
 arrays={k:np.load(p/'targets.npy') for k,p in folders.items()};reference=arrays['default'];mask=np.load(folders['default']/'mask.npy').astype(bool)
 for name,folder in folders.items():
  for file in ['targets.npy','mask.npy','inputs.npy','meta.json']:pins[str(folder/file)]=digest(folder/file)
  for file in ['inputs.npy','mask.npy']:assert digest(folder/file)==digest(folders['default']/file)
  assert arrays[name].shape==reference.shape and np.isfinite(arrays[name]).all()
 bad={c:set(np.flatnonzero(mask & (np.abs(arrays['cuda'][c].astype(float)-reference[c].astype(float))>(.05+.002*np.abs(reference[c].astype(float))))).tolist()) for c in [0,2]}
 for index in sorted(bad[0]|bad[2]):
  row,col=divmod(index,mask.shape[1]);prefix=f'{case}-{index}'
  point=dict(id=prefix,case=case,columnIndex=index,failedChannels=[c for c in [0,2] if index in bad[c]],loads={})
  for name,a in arrays.items():
   pair=[float(a[0,row,col]),float(a[2,row,col])];ident=prefix+'-'+name
   loads.append(dict(id=ident,peakPa=pair[0],impulsePaS=pair[1]));point['loads'][name]=ident;source_pairs[ident]=pair
  base=source_pairs[point['loads']['default']];cuda=source_pairs[point['loads']['cuda']]
  for name,pair in [('repeat',base),('cudaPeak',[cuda[0],base[1]]),('cudaPhase',[base[0],cuda[1]])]:
   ident=prefix+'-'+name;loads.append(dict(id=ident,peakPa=pair[0],impulsePaS=pair[1]));point['loads'][name]=ident;source_pairs[ident]=pair
  points.append(point)
fixtures=[dict(id='rc-wall-6x4',kind='wall',material='reinforcedConcrete',widthM=6,heightM=4,thicknessM=.2),dict(id='brick-wall-6x3',kind='wall',material='unreinforcedMasonry',widthM=6,heightM=3,thicknessM=.215),dict(id='glass-1.5x1.25',kind='pane',material='reinforcedConcrete',widthM=1.5,heightM=1.25,thicknessM=.006),dict(id='rc-roof-6x4',kind='roof',material='reinforcedConcrete',widthM=6,heightM=4,thicknessM=.2)]
sweep=dict(name='receiver-fixtures-20261021',inputs=[],cases=[])
for binS in [2e-4,1e-4,5e-5]:
 path=root/f'input-{binS}.json';path.write_text(json.dumps(dict(format='bombcad-receiver-fixtures-1',binS=binS,riseShare=.2,loads=loads,fixtures=fixtures),indent=2)+'\n')
 sweep['inputs'].append(str(path));sweep['cases'].append(dict(name=f'bin-{binS}',args=['receiver-fixtures','--input',str(path),'--out','{out}/results.json']))
(root/'sweep.json').write_text(json.dumps(sweep,indent=2)+'\n')
report=dict(status='prepared',scope='Actual rejected point peak/first-phase pairs applied uniformly to predeclared component fixtures. Hypothetical sensitivity, not inferred area loads, full histories, physical validation or dataset admission.',revisionObserved=__import__('subprocess').check_output(['git','rev-parse','HEAD'],text=True).strip(),points=points,sourcePairs=source_pairs,fixtures=fixtures,sourceSHA256=pins,bins=[2e-4,1e-4,5e-5],riseShare=.2,assumptions='All four edges supported, ordinary construction defaults including reinforcement ratio .003; pane material follows glass thickness, material field is unused for panes. Fixed/simple support response ranges retained. No tuned load factor or strength.')
(root/'study.json').write_text(json.dumps(report,indent=2)+'\n');print('Prepared',len(points),'rejected receiver points',len(loads),'load variants',len(fixtures),'fixtures',len(sweep['cases']),'bins')
