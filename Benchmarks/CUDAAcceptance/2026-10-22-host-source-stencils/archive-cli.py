"""Archive every frozen CLI-control file; publish all non-runtime evidence by kind."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    here=Path(__file__).resolve().parent
    root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-host-source-cli-control')
    context=json.loads((root/'context.json').read_text());assert context['status']=='pass'
    assert len(context['commands'])==4 and all(c['status']=='terminal' for c in context['commands'])
    assert all(sha(p['original'])==sha(p['snapshot'])==p['sha256'] for p in context['frozenSources'])
    assert all(sha(root/'runtime'/n)==s for n,s in context['runtimeSHA256'].items())
    support=root/'archive-support';support.mkdir(exist_ok=False)
    shutil.copyfile(__file__,support/'archive-cli.py')
    shutil.copyfile(here.parent/'2026-10-22-compensated-peaks/archive.py',support/'pack.py')
    sys.dont_write_bytecode=True
    spec=importlib.util.spec_from_file_location('verified_pack',support/'pack.py');pack=importlib.util.module_from_spec(spec);spec.loader.exec_module(pack)
    names=sorted(str(p.relative_to(root)) for p in root.rglob('*') if p.is_file())
    pins={n:dict(sha256=sha(root/n),bytes=(root/n).stat().st_size) for n in names}
    external=root.with_name(root.name+'-archive');external.mkdir(exist_ok=False)
    public=here/'evidence';public.mkdir(exist_ok=False)
    full=pack.pack(root,names,external/'all-raw.tar.gz',pins,1)
    metadata=[n for n in names if Path(n).parts[0]!='runtime']
    published=pack.pack(root,metadata,public/'cli-control.tar.gz',pins,6)
    assert all(sha(root/n)==p['sha256'] for n,p in pins.items())
    receipt=dict(schema='bombcad-host-source-cli-archive-1',rawRoot=str(root),rawFiles=pins,rawBytes=sum(p['bytes'] for p in pins.values()),
        externalArchive=full,publishedEvidence=published,
        scope='All four-mode synthetic CLI-control output/source/log/receipt files retained. Runtime binaries/resources external-only by kind. No scientific fine-grid result or hermetic-runtime claim.')
    with (here/'archive.json').open('x') as stream:json.dump(receipt,stream,indent=2);stream.write('\n')
    summary={k:v for k,v in context.items() if k not in ['frozenSources','runtimeSHA256']}
    summary['frozenSourceFiles']=len(context['frozenSources']);summary['frozenRuntimeFiles']=len(context['runtimeSHA256'])
    summary['contextSHA256']=sha(root/'context.json')
    (here/'cli-control-results.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({k:v for k,v in receipt.items() if k!='rawFiles'},indent=2))


if __name__=='__main__':main()
