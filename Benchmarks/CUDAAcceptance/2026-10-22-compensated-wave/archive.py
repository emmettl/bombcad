"""Archive and independently verify every raw file; publish metadata by kind, never outcome."""
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
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def pack(root, names, destination, inventory, level):
    with destination.open('xb') as output:
        with gzip.GzipFile(filename='',mode='wb',compresslevel=level,mtime=0,fileobj=output) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|') as archive:
                for name in names:archive.add(root/name,arcname=name,recursive=False)
    verified=0
    with tarfile.open(destination,mode='r|gz') as archive:
        for member in archive:
            assert member.isfile() and member.name in inventory
            h=hashlib.sha256();stream=archive.extractfile(member);size=0
            for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk);size+=len(chunk)
            assert h.hexdigest()==inventory[member.name]['sha256'] and size==inventory[member.name]['bytes']
            verified+=1
    assert verified==len(names)
    return dict(path=str(destination),files=len(names),bytes=destination.stat().st_size,
                sha256=sha(destination),uncompressedBytes=sum(inventory[n]['bytes'] for n in names),
                everyMemberIndependentlyVerified=True)


def main(root, publication):
    root=Path(root).resolve();publication=Path(publication).resolve()
    run=json.loads((root/'run.json').read_text())
    assert run['status'] in ['complete','complete-with-failures'] and 'liveProcess' not in run
    final=json.loads((root/'audit-v2/final.json').read_text());assert final['status']=='complete-all-outcome-audit'
    assert not (root/'archive.json').exists()
    names=sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
    inventory={n:dict(bytes=(root/n).stat().st_size,sha256=sha(root/n)) for n in names}
    external=root.with_name(root.name+'-archive');external.mkdir(exist_ok=False)
    publication.mkdir(exist_ok=False)
    full=pack(root,names,external/'all-raw.tar.gz',inventory,1)
    groups=defaultdict(list);excluded=[]
    for name in names:
        parts=Path(name).parts
        if '__pycache__' in parts:excluded.append(name);continue
        if parts[0]=='cases':
            if name.endswith('-trace.json'):
                excluded.append(name);continue
            groups['-'.join(parts[1].split('-')[:4])].append(name)
        elif parts[0] in ['sources','analysis','logs','early-contract-check','early-contract-check-v2','early-factor-contract-check-v2','audit-v2']:
            if Path(name).suffix=='.npz':excluded.append(name)
            else:groups['audit-sources-logs'].append(name)
        elif len(parts)==1:groups['audit-sources-logs'].append(name)
        else:excluded.append(name)
    published=[pack(root,items,publication/(label+'.tar.gz'),inventory,6) for label,items in sorted(groups.items())]
    # Recheck original files after compression; an observation never mutates producer data.
    assert all(sha(root/n)==pin['sha256'] for n,pin in inventory.items())
    result=dict(schema='bombcad-compensated-wave-archive-1',rawRoot=str(root),
        allRawFiles=inventory,externalArchive=full,publishedMetadataArchives=published,
        externalOnlyFiles=excluded,publicationRule='All case statuses retained. Omit raw trace JSON, numerical NPZ and runtime binaries from the public subset by file kind only; every file remains in the independently verified external archive.')
    (root/'archive.json').write_text(json.dumps(result,indent=2)+'\n')
    (publication.parent/'archive.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(rawFiles=len(names),rawBytes=sum(p['bytes'] for p in inventory.values()),external=full,publishedFiles=sum(p['files'] for p in published),publishedBytes=sum(p['bytes'] for p in published)),indent=2))


if __name__=='__main__':main(*sys.argv[1:])
