import hashlib,importlib.util,json,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path('Scripts/cuda').resolve()));s=importlib.util.spec_from_file_location('q','Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
from generate import generate
from job import validate
root=Path('/private/tmp/bombcad-independent-portability/smoke');root.mkdir(exist_ok=False)
exe=str(Path('.build/release/scenebench').resolve());source=root/'solver.cu';source.write_text(generate());slot='/Users/louisemmett/.local/bin/gpu-slot'
args=['--osm',str(Path('Samples/MapBuildings/synthetic-neighbourhood.geojson').resolve()),'--centre','0.00045,51.50028','--radius','48','--dx','2','--height','32','--mass','10','--until','.08','--above','1','--id','initial-smoke','--first-phase']
rows=[]
for name,extra in [('plain',[]),('observed',['--initial-state-diagnostic',str(root/'initial-tiled'),'--cuda-source',str(source)]),('full',['--full-grid-diagnostic','--initial-state-diagnostic',str(root/'initial-full'),'--cuda-source',str(source)])]:
 with (root/(name+'.log')).open('w') as log:subprocess.run([slot,'--mem','1',exe,'field-export',*args,*extra,'--out',str(root/name)],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
rows.append(dict(observerArraysBitIdentical=all(q.digest(root/'plain'/n)==q.digest(root/'observed'/n) for n in ['inputs.npy','mask.npy','targets.npy'])))
a,_=validate(root/'initial-tiled',source.read_text());b,_=validate(root/'initial-full',source.read_text());rows.append(dict(physicalBuffersIdenticalAcrossPaths=a['files']==b['files']))
assert all(next(iter(x.values())) for x in rows)
existing=root/'existing';existing.mkdir();(existing/'marker').write_text('preserve')
for name,changed,extra in [
 ('missing-phase',[v for v in args if v!='--first-phase'],['--initial-state-diagnostic',str(root/'bad-initial-1'),'--cuda-source',str(source)]),
 ('missing-source',args,['--initial-state-diagnostic',str(root/'bad-initial-2')]),
 ('same-output',args,['--initial-state-diagnostic',str(root/'bad-same-output'),'--cuda-source',str(source)]),
 ('nested-output',args,['--initial-state-diagnostic',str(root/'bad-nested-output'/'initial'),'--cuda-source',str(source)]),
 ('existing',args,['--initial-state-diagnostic',str(existing),'--cuda-source',str(source)]),
 ('cuda-job',args,['--initial-state-diagnostic',str(root/'bad-initial-3'),'--cuda-source',str(source),'--cuda-job']),
 ('missing-value',args,['--cuda-source',str(source),'--initial-state-diagnostic'])]:
 out=root/('bad-'+name+'-output')
 if name=='same-output':out=root/'bad-same-output'
 if name=='nested-output':out=root/'bad-nested-output'
 with (root/(name+'.log')).open('w') as log:p=subprocess.run([exe,'field-export',*changed,'--out',str(out),*extra],stdout=log,stderr=subprocess.STDOUT,timeout=30)
 assert p.returncode!=0 and not out.exists(),name
 rows.append(dict(control=name,rejected=True,outputCreated=False))
assert (existing/'marker').read_text()=='preserve'
(root/'smoke.json').write_text(json.dumps(dict(status='complete',controls=rows,executableSHA256=q.digest(exe)),indent=2)+'\n');print('Snapshot transparency and seven rejection controls passed')
