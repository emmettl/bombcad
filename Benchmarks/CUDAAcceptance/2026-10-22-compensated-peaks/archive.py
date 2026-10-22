"""Archive all saved-history outputs and verify each decompressed member."""
import gzip
import hashlib
import json
from pathlib import Path
import sys
import tarfile


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def pack(root,names,target,pins,level):
    with target.open('xb') as output:
        with gzip.GzipFile(filename='',mode='wb',compresslevel=level,mtime=0,fileobj=output) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|') as archive:
                for name in names:archive.add(root/name,arcname=name,recursive=False)
    seen=[]
    with tarfile.open(target,mode='r|gz') as archive:
        for member in archive:
            assert member.isfile() and member.name in pins and member.name not in seen
            h=hashlib.sha256();size=0;stream=archive.extractfile(member)
            for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk);size+=len(chunk)
            assert h.hexdigest()==pins[member.name]['sha256'] and size==pins[member.name]['bytes']
            seen.append(member.name)
    assert sorted(seen)==sorted(names)
    return dict(path=str(target),files=len(names),bytes=target.stat().st_size,sha256=sha(target),everyDecompressedMemberVerified=True)


def main(root,publication):
    root=Path(root).resolve();publication=Path(publication).resolve()
    result=json.loads((root/'results.json').read_text());context=json.loads((root/'context.json').read_text())
    assert result['status'] in ['complete','complete-with-failures'] and context['status']==result['status']
    assert result['caseGroups']==len(result['rows'])==432
    names=sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
    pins={n:dict(sha256=sha(root/n),bytes=(root/n).stat().st_size) for n in names}
    target=root.with_name(root.name+'-archive');target.mkdir(exist_ok=False);publication.mkdir(exist_ok=False)
    all_files=pack(root,names,target/'all-raw.tar.gz',pins,1)
    metadata=[n for n in names if Path(n).suffix!='.npz']
    published=pack(root,metadata,publication/'metadata.tar.gz',pins,6)
    assert all(sha(root/n)==pin['sha256'] for n,pin in pins.items())
    receipt=dict(schema='bombcad-saved-peaks-archive-1',rawRoot=str(root),rawFiles=pins,rawBytes=sum(x['bytes'] for x in pins.values()),
        externalArchive=all_files,publishedMetadata=published,
        scope='Every case outcome retained. Only derived NPZ arrays are external-only by kind; all input histories remain hash-pinned in the preceding compensated-wave archive.')
    with (publication.parent/'archive.json').open('x') as stream:json.dump(receipt,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in receipt.items() if k!='rawFiles'},indent=2))


if __name__=='__main__':main(*sys.argv[1:])
