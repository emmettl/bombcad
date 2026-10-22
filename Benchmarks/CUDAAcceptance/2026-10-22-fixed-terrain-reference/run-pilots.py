"""One-attempt fixed-main Metal/CUDA pilots; no dataset index mutation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')
REPO=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent


def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as s:
        for b in iter(lambda:s.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


def save(p,value):
    p=Path(p);temporary=p.with_suffix('.tmp');temporary.write_text(json.dumps(value,indent=2)+'\n');os.replace(temporary,p)


def files(root):
    for folder,dirs,names in os.walk(root):
        dirs[:]=[n for n in dirs if n!='__pycache__' and not any(x in n.lower() for x in ['blind','vasudev'])]
        for n in sorted(names):
            if not any(x in n.lower() for x in ['blind','vasudev']):yield Path(folder)/n


def main():
    revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
    subprocess.run(['git','merge-base','--is-ancestor','aff21dff',revision],cwd=REPO,check=True)
    exe=(REPO/'.build/release/scenebench').resolve();assert exe.is_file()
    assert shutil.disk_usage(ROOT.parent).free>128*2**30
    ROOT.mkdir(exist_ok=False)
    for n in ['runtime','sources','inputs','cases','analysis']:(ROOT/n).mkdir()
    shutil.copyfile(exe,ROOT/'runtime/scenebench');(ROOT/'runtime/scenebench').chmod(0o755)
    for b in exe.parent.glob('*.bundle'):
        if 'test' not in b.name.lower():shutil.copytree(b,ROOT/'runtime'/b.name)
    chosen=[REPO/'Package.swift',HERE/'plan.md',Path(__file__).resolve(),REPO/'Scripts/ml/field-runs.py',REPO/'Scripts/ml/field-runs.json']
    for directory in ['Sources','Scripts/cuda']:
        chosen+=list(files(REPO/directory))
    source_pins=[]
    for i,p in enumerate(chosen):
        dest=ROOT/'sources'/f'{i:04d}-{p.name}';shutil.copyfile(p,dest)
        source_pins.append(dict(original=str(p),snapshot=str(dest),sha256=sha(dest)))
    shutil.copytree(REPO/'Scripts/cuda',ROOT/'analysis/cuda',ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copyfile(REPO/'Scripts/ml/remote-train.py',ROOT/'analysis/remote-train.py')
    # remote.py expects its sibling ../ml/remote-train.py.
    (ROOT/'analysis/ml').mkdir();shutil.copyfile(REPO/'Scripts/ml/remote-train.py',ROOT/'analysis/ml/remote-train.py')
    shutil.copyfile(__file__,ROOT/'analysis/run-pilots.py')
    sys.path.insert(0,str(ROOT/'analysis/cuda'))
    # generate() reads production source relative to its original repository path.
    generated=load_module('original_generate',REPO/'Scripts/cuda/generate.py').generate()
    (ROOT/'solver.cu').write_text(generated)
    plan=load_module('field_plan',REPO/'Scripts/ml/field-runs.py');data=json.loads(Path(plan.LIST).read_text())
    identifiers=['made-perimeter-s1-1','made-perimeter-s3-1','beirut-p0-1'];jobs=[]
    for name in identifiers:
        run=next(r for r in data['sets']['main'] if r['id']==name);layout=data['layouts'][run['layout']]
        original=plan.inputs_for(run['layout'],layout,make=False);copied=dict(original)
        for field in ['osm','dem','heights']:
            if original.get(field):
                p=Path(original[field]);dest=ROOT/'inputs'/name/(field+p.suffix);dest.parent.mkdir(exist_ok=True)
                shutil.copyfile(p,dest);copied[field]=str(dest)
        folder=ROOT/'cases'/name;folder.mkdir()
        args=plan.field_arguments(run,layout,copied,str(folder/'metal'))
        args+=['--first-phase','--initial-state-diagnostic',str(folder/'input'),'--cuda-source',str(ROOT/'solver.cu')]
        jobs.append(dict(id=name,run=run,arguments=args,originalInputs=original))
    pins={str(p.relative_to(ROOT)):dict(sha256=sha(p),bytes=p.stat().st_size) for group in ['runtime','sources','inputs','analysis'] for p in files(ROOT/group)}
    report=dict(status='running',revision=revision,fix='aff21dff',sourcePins=source_pins,frozenFiles=pins,generatedSourceSHA256=sha(ROOT/'solver.cu'),jobs=jobs,commands=[],rows=[],controllerPID=os.getpid())
    save(ROOT/'run.json',report)
    env=dict(os.environ,BOMBCAD_SOURCE_REVISION=revision)
    for key in list(env):
        if key.startswith('GPU_SLOT_') or key.startswith('BOMBCAD_KERNEL_') or key in ['PACKAGE_RESOURCE_BUNDLE_PATH','PACKAGE_RESOURCE_BUNDLE_URL']:env.pop(key,None)
    try:
        for job in jobs:
            name=job['id'];folder=ROOT/'cases'/name
            assert all(sha(ROOT/n)==pin['sha256'] for n,pin in pins.items())
            assert all(sha(p['original'])==p['sha256'] for p in source_pins)
            command=[str(Path.home()/'.local/bin/gpu-slot'),'--mem',str(job['run']['estimate']['memGB']),str(ROOT/'runtime/scenebench'),*job['arguments']]
            entry=dict(id=name,backend='metal',command=command,status='running');report['commands'].append(entry);save(ROOT/'run.json',report)
            with (folder/'metal.log').open('wb') as log:
                process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env,start_new_session=True);entry['pid']=process.pid;save(ROOT/'run.json',report);entry['returncode']=process.wait()
            entry['status']='complete' if entry['returncode']==0 else 'failed';save(ROOT/'run.json',report)
            if entry['returncode']:
                report['rows'].append(dict(id=name,status='metal-failed',eligible=False));continue
            # Use the deployed worker from the checkout: remote.generate() must resolve original sources.
            command=[sys.executable,'-B',str(REPO/'Scripts/cuda/remote.py'),'bombcad-pc',str(folder/'input'),'--out',str(folder/'cuda'),'--dataset-only']
            entry=dict(id=name,backend='cuda',command=command,status='running');report['commands'].append(entry);save(ROOT/'run.json',report)
            with (folder/'cuda.log').open('wb') as log:
                process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,env=env,start_new_session=True);entry['pid']=process.pid;save(ROOT/'run.json',report);entry['returncode']=process.wait()
            entry['status']='complete' if entry['returncode']==0 else 'failed'
            if entry['returncode']:report['rows'].append(dict(id=name,status='cuda-failed',eligible=False))
            else:
                compare=load_module('compare_fixed',ROOT/'analysis/cuda/compare_dataset.py').compare
                comparison=compare(folder/'metal',folder/'cuda/dataset')
                report['rows'].append(dict(id=name,status='compared',eligible=comparison['passed'],comparison=comparison,
                    metal=json.loads((folder/'metal/meta.json').read_text()),cuda=json.loads((folder/'cuda/result.json').read_text()),
                    initial=json.loads((folder/'input/initial-diagnostic.json').read_text())))
            save(ROOT/'run.json',report)
        assert all(sha(ROOT/n)==pin['sha256'] for n,pin in pins.items())
        assert all(sha(p['original'])==p['sha256'] for p in source_pins)
        report['status']='complete-all-outcomes';report['allPilotsPass']=all(r['eligible'] for r in report['rows']) and len(report['rows'])==3
    except BaseException as error:report['status']='failed';report['error']=repr(error);raise
    finally:save(ROOT/'run.json',report)


if __name__=='__main__':main()
