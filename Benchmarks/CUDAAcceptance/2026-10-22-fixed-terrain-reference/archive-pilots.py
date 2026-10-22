"""Archive all completed fixed-reference pilot outcomes; publish metadata by kind."""
import importlib.util
import json
from pathlib import Path
import sys

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('verified_archive',HERE.parent/'2026-10-22-host-source-stencils/archive-scientific.py')
archive=importlib.util.module_from_spec(spec);spec.loader.exec_module(archive)


def main(root):
    root=Path(root).resolve()
    producer=json.loads((root/'run.json').read_text());queue=json.loads((root/'queued-cuda/run.json').read_text());audit=json.loads((root/'target-audit.json').read_text())
    assert producer['status']==queue['status']=='complete-all-outcomes'
    assert len(audit['rows'])==len(queue['rows'])==len(producer['jobs'])==3
    assert {r['id'] for r in audit['rows']}=={j['id'] for j in producer['jobs']}
    names=sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
    pins={name:dict(sha256=archive.sha(root/name),bytes=(root/name).stat().st_size) for name in names}
    destination=root.with_name(root.name+'-archive');destination.mkdir(exist_ok=False)
    full=archive.pack(root,names,destination/'all-raw.tar.gz',pins,1)
    metadata=[];excluded=[]
    for name in names:
        p=Path(name);parts=p.parts
        if p.suffix=='.npy' or parts[0] in ['runtime','inputs'] or '__pycache__' in parts:excluded.append(name)
        else:metadata.append(name)
    publication=HERE/'evidence/pilots-metadata.tar.gz'
    public=archive.pack(root,metadata,publication,pins,6)
    assert all(archive.sha(root/name)==pin['sha256'] for name,pin in pins.items())
    receipt=dict(schema='bombcad-fixed-terrain-pilots-archive-1',rawRoot='$BOMBCAD_DATA/experiments/'+root.name,
        files=pins,rawFiles=len(names),rawBytes=sum(x['bytes'] for x in pins.values()),
        externalArchive=dict(full,path='$BOMBCAD_DATA/experiments/'+destination.name+'/all-raw.tar.gz'),
        publishedMetadata=dict(public,path='evidence/pilots-metadata.tar.gz'),externalOnlyFiles=excluded,
        scope='Every pilot and original lock-refusal outcome retained. All local numerical input/target arrays, input geodata and runtime resources external-only by kind, never status. PC full-state outputs remain at the separately identified remote job paths. All local raw files archived and every decompressed member verified; public metadata does not imply complete remote-state archival or physical validation.')
    with (HERE/'pilot-archive.json').open('x') as stream:json.dump(receipt,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in receipt.items() if k not in ['files','externalOnlyFiles']},indent=2))


if __name__=='__main__':main(sys.argv[1])
