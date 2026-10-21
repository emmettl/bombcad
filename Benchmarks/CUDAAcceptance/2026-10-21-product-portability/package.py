"""Retain fields, tables, outcomes and failed attempts; map/history assets are hash-pinned local prerequisites."""
import hashlib,json,shutil,subprocess,tarfile
from pathlib import Path
repo=Path.cwd();tmp=Path('/private/tmp/bombcad-product-portability');root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-product-portability-v4');dest=repo/'Benchmarks/CUDAAcceptance/2026-10-21-product-portability';dest.mkdir(exist_ok=True)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
r=json.loads((root/'study.json').read_text());a=json.loads((root/'analysis.json').read_text());assert r['status']==a['status']=='complete'
for p,h in r['pinsSHA256'].items():assert digest(p)==h,p
original=json.loads((repo/'Benchmarks/CUDAAcceptance/2026-10-21-reference-spread/study.json').read_text())
for name,folder in r['fieldFolders'].items():
 expected=original['inputSHA256'][{'full':'default-full','cuda':'candidate'}.get(name,name)]
 for file,h in expected.items():assert digest(Path(folder)/file)==h,(name,file)
assert all(p['changed']==0 and p['maxAbsolute']==0 for v in a['variants'].values() for ps in v.values() for p in ps)
for name in ['study.py','run.py','analyse.py','lf-control.py','finish.py','package.py','preflight-initial.py.txt','preflight-v2.py.txt','preflight-v3.py.txt','preflight-initial.log','preflight-v2.log','preflight-v3.log','study-v4.log','analysis.log','lf-control.log','build-crlf.log','build-newline.log','newline-control.log']:shutil.copy2(tmp/name,dest/name)
shutil.copy2('/private/tmp/bombcad-product-portability-build.log',dest/'build-initial.log')
for name in ['study.json','analysis.json','lf-control.json']:shutil.copy2(root/name,dest/name)
source=repo/'Sources/SceneBench/FieldWalls.swift'
earlier=source.read_text().replace('.split(whereSeparator: \\.isNewline)','.split(separator: "\\n")');(tmp/'FieldWalls-trim-only.swift.txt').write_text(earlier)
failed3=json.loads((root.parent/'2026-10-21-product-portability-v3/study.json').read_text());assert digest(tmp/'FieldWalls-trim-only.swift.txt')==failed3['pinsSHA256'][str(source)]
(tmp/'FieldWalls-original.swift.txt').write_bytes(subprocess.check_output(['git','show','HEAD:Sources/SceneBench/FieldWalls.swift']))
failed2=json.loads((root.parent/'2026-10-21-product-portability-v2/study.json').read_text());assert digest(tmp/'FieldWalls-original.swift.txt')==failed2['pinsSHA256'][str(source)]
entries=[(p,'completed/'+str(p.relative_to(root))) for p in sorted(root.rglob('*'))]
for suffix in ['', '-v2','-v3']:
 old=root.parent/('2026-10-21-product-portability'+suffix)
 entries += [(p,'failed'+(suffix or '-initial')+'/'+str(p.relative_to(old))) for p in sorted(old.rglob('*'))]
for name,folder in r['fieldFolders'].items():entries += [(Path(folder)/file,'fields/'+name+'/'+file) for file in ['inputs.npy','mask.npy','targets.npy','meta.json']]
entries += [(Path('/Volumes/StudioData/bombcad/ml/judge/strips/beirut-p0-1.csv'),'sampling/strips.csv'),(Path('/Volumes/StudioData/bombcad/ml/judge/fpw/peaks/beirut-p0-1.csv'),'sampling/published-peaks.csv')]
entries += [(tmp/name,'failed-source/'+name) for name in ['FieldWalls-original.swift.txt','FieldWalls-trim-only.swift.txt']]
seen={};files={};links=0
with tarfile.open(dest/'state.tar.gz','w:gz') as archive:
 for p,name in entries:
  info=archive.gettarinfo(str(p),arcname=name)
  if info.isfile():
   h=digest(p);files[name]=h;key=(h,info.size,info.mode)
   if p.suffix in ['.npy','.bin'] and info.size>=4096 and key in seen:info.type=tarfile.LNKTYPE;info.linkname=seen[key];info.size=0;archive.addfile(info);links+=1
   else:
    if p.suffix in ['.npy','.bin'] and info.size>=4096:seen[key]=name
    with p.open('rb') as f:archive.addfile(info,f)
  elif info.isdir():archive.addfile(info)
  else:raise ValueError(str(p))
actual={}
with tarfile.open(dest/'state.tar.gz','r|gz') as archive:
 for info in archive:
  if info.isfile():actual[info.name]=hashlib.sha256(archive.extractfile(info).read()).hexdigest()
  elif info.islnk():actual[info.name]=actual[info.linkname]
assert actual==files
write(dest/'archive-files.json',files);write(dest/'archive-audit.json',dict(status='complete',filesVerified=len(actual),payloadLinks=links,archiveBytes=(dest/'state.tar.gz').stat().st_size,originalFieldHashesMatchPublishedSpread=True,allProductDifferencesZero=True,notArchived='Original map raster/OSM assets and recorded strip/component histories are hash-pinned local prerequisites; full field arrays, sampled loads and judged outcomes are retained.'))
print('Verified',len(actual),'files',links,'payload links',(dest/'state.tar.gz').stat().st_size,'bytes')
