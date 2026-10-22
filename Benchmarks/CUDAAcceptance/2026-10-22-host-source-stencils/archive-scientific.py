"""Archive every scientific outcome and verify decompressed members; publish by kind."""
from collections import defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import sys
import tarfile


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def pack(root,names,target,pins,level):
    with target.open('xb') as output:
        with gzip.GzipFile(filename='',mode='wb',compresslevel=level,mtime=0,fileobj=output) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|') as archive:
                for name in names:archive.add(root/name,arcname=name,recursive=False)
    seen=set()
    with tarfile.open(target,mode='r|gz') as archive:
        for member in archive:
            assert member.isfile() and member.name in pins and member.name not in seen
            h=hashlib.sha256();size=0;stream=archive.extractfile(member)
            for block in iter(lambda:stream.read(1024*1024),b''):h.update(block);size+=len(block)
            assert h.hexdigest()==pins[member.name]['sha256'] and size==pins[member.name]['bytes']
            seen.add(member.name)
    assert seen==set(names)
    return dict(path=str(target),files=len(names),bytes=target.stat().st_size,sha256=sha(target),everyDecompressedMemberVerified=True)


def main(root,publication):
    root=Path(root).resolve();publication=Path(publication).resolve()
    run=json.loads((root/'run.json').read_text());audit=json.loads((root/'audit/results.json').read_text())
    assert run['status'] in ['complete','complete-with-failures'] and 'liveProcess' not in run
    assert audit['status']=='complete-all-outcome-source-audit' and len(audit['rows'])==432
    assert (root/'summary.json').is_file()
    names=sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
    pins={name:dict(sha256=sha(root/name),bytes=(root/name).stat().st_size) for name in names}
    external=root.with_name(root.name+'-archive');external.mkdir(exist_ok=False);publication.mkdir(exist_ok=False)
    full=pack(root,names,external/'all-raw.tar.gz',pins,1)
    groups=defaultdict(list);excluded=[]
    for name in names:
        p=Path(name);parts=p.parts
        if '__pycache__' in parts or p.suffix=='.npz' or parts[0] in ['runtime','runtime-pins']:
            excluded.append(name)
        elif parts[0]=='cases':
            if name.endswith('-trace.json') or name.endswith('-source-stencil.json'):excluded.append(name)
            else:groups['-'.join(parts[1].split('-')[:4])].append(name)
        else:groups['sources-audit-metadata'].append(name)
    published=[pack(root,value,publication/(key+'.tar.gz'),pins,6) for key,value in sorted(groups.items())]
    assert all(sha(root/name)==pin['sha256'] for name,pin in pins.items())
    receipt=dict(schema='bombcad-host-source-scientific-archive-1',rawRoot=str(root),allRawFiles=pins,
        rawFiles=len(names),rawBytes=sum(x['bytes'] for x in pins.values()),externalArchive=full,publishedMetadataArchives=published,
        externalOnlyFiles=excluded,publicationRule='All statuses retained. Complete source/pressure/update traces, numerical NPZ arrays and runtime binaries excluded from public subset by kind only; all retained and independently verified in external archive.')
    with (publication.parent.parent/'scientific-archive.json').open('x') as stream:json.dump(receipt,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in receipt.items() if k not in ['allRawFiles','externalOnlyFiles','publishedMetadataArchives']},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
