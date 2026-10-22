"""Immutable single-attempt compensated-wave matrix controller; preserves all adverse outcomes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import platform
import sys


def blocked(name):return 'blind' in name.lower() or 'vasudev' in name.lower()

def skip_sealed(directory,names):return [name for name in names if blocked(name)]

def safe_files(root):
    for directory,folders,files in os.walk(root):
        folders[:]=[name for name in folders if not blocked(name)]
        for name in files:
            if not blocked(name):yield Path(directory)/name


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def atomic(path,value):
    path=Path(path);temporary=path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value,indent=2)+'\n');os.replace(temporary,path)

def boot_id():return subprocess.check_output(['sysctl','-n','kern.boottime'],text=True).strip()

def process_snapshot(pid):
    env=dict(os.environ,LC_ALL='C',TZ='UTC')
    result=subprocess.run(['ps','-ww','-p',str(pid),'-o','lstart=','-o','stat=','-o','command='],capture_output=True,text=True,env=env)
    parts=result.stdout.strip().split(None,6)
    return {'birth':' '.join(parts[:5]),'state':parts[5],'command':parts[6]} if result.returncode==0 and len(parts)==7 else None

def group_alive(pid):
    data=subprocess.check_output(['ps','-axo','pgid=,stat='],text=True)
    return any(int(parts[0])==pid and not parts[1].startswith('Z') for line in data.splitlines() if len(parts:=line.split())>=2)

def clean_env(contract):
    env=dict(os.environ)
    for key in list(env):
        if key.startswith('GPU_SLOT_') or key in ['BOMBCAD_KERNEL_MATH','BOMBCAD_KERNEL_CONTRACT','BOMBCAD_STATE_PADDING','BOMBCAD_STATE_PADDING_AT','BOMBCAD_KERNEL_PERTURB','BOMBCAD_GPU_SLOTS','BOMBCAD_GPU_SLOT_DIR','BOMBCAD_GPU_MEM_BUDGET','BOMBCAD_GPU_MEM_FORCE']:env.pop(key,None)
    env['BOMBCAD_SOURCE_REVISION']=contract['revisionObservedAtInit']+('-dirty' if contract['worktreeDirtyAtInit'] else '')
    return env


def plan():
    jobs=[]
    for retain in [True,False]:
        for policy in ['default','unfused']:
            for cfl in ['0.45','0.225']:
                for component in ['density','energy','both']:
                    for amplitude in [1,10,100]:
                        for nx in [512,1024,2048]:
                            for tiled in [False,True]:
                                case=f'a{amplitude}-n{nx}-'+('tiled' if tiled else 'full')
                                method='protected-kahan-v1' if retain else 'protected-update-no-carry-v1'
                                label=f'{"retain" if retain else "discard"}-{policy}-cfl{cfl}-{component}-{case}'
                                args=['acoustic-phase','--fine','--trace-updates','--rounding',policy,'--cfl',cfl,'--compensated',component,'--only-case',case]
                                if not retain:args+=['--discard-compensation']
                                jobs.append(dict(label=label,case=case,method=method,policy=policy,cfl=cfl,components=component,amplitudePa=amplitude,nx=nx,tiled=tiled,arguments=args))
    assert len(jobs)==432 and len({j['label'] for j in jobs})==432
    return dict(schema='bombcad-compensated-wave-plan-1',caseGroups=432,expectedExports=1296,jobs=jobs)


def run():
    repo=Path.cwd();here=Path(__file__).resolve().parent
    # This guard precedes creation of a persistent experiment root.
    for name in ['plan.md','audit.py','replay.py','reference-worker.py','readouts.py','phase.py','oracles.py','finalize.py','baseline.json','device.swift']:
        if not (here/name).is_file():raise RuntimeError('Final frozen auditor/plan not ready: '+name)
    import numpy as np
    exe=Path('.build/release/blastbench').resolve()
    expected=json.loads((here/'final-checks.json').read_text())
    if digest(exe)!=expected['currentExecutable']['sha256']:raise RuntimeError('cached executable differs from verified implementation; inspect/reverify before execution')
    pinned=json.loads((here/'final-source-pins.json').read_text())
    if not all(digest(name)==sha for name,sha in pinned['sourceSHA256'].items() if not any(blocked(part) for part in Path(name).parts)):raise RuntimeError('implementation source pins changed before freeze')
    root=Path(os.environ.get('BOMBCAD_DATA','/Volumes/StudioData/bombcad'))/'experiments/2026-10-22-compensated-wave'
    root.mkdir(parents=True,exist_ok=False)
    (root/'logs').mkdir();(root/'cases').mkdir();(root/'sources').mkdir();(root/'runtime').mkdir();(root/'analysis').mkdir();(root/'analysis/cuda').mkdir()
    for p in here.glob('*.py'):shutil.copyfile(p,root/'analysis'/p.name)
    shutil.copyfile(here/'baseline.json',root/'analysis/baseline.json')
    for name in ['diagnose-phase.py','trace_columns.py','compare_dataset.py']:shutil.copyfile(repo/'Scripts/cuda'/name,root/'analysis/cuda'/name)
    shutil.copyfile(repo/'Scripts/reference/planar_euler.py',root/'analysis/planar_euler.py')
    revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    dirty=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip())
    frozen=[]
    paths=[Path(__file__).resolve(),*[here/name for name in ['plan.md','audit.py','replay.py','reference-worker.py','readouts.py','phase.py','oracles.py','finalize.py']],repo/'Scripts/reference/planar_euler.py',repo/'Scripts/cuda/diagnose-phase.py',repo/'Scripts/cuda/trace_columns.py',repo/'Scripts/cuda/compare_dataset.py',repo/'Package.swift',here/'device.swift']
    for module in ['BlastCore','BlastModel','blastbench']:paths+=sorted(p for p in safe_files(repo/'Sources'/module) if p.suffix=='.swift')
    paths+=sorted((repo/'Sources/BlastCore/Shaders').glob('*.metal'))
    for i,p in enumerate(paths):
        destination=root/'sources'/f'{i:04d}-{p.name}';shutil.copyfile(p,destination)
        frozen.append(dict(original=str(p),path=str(destination),sha256=digest(destination)))
    shutil.copyfile(exe,root/'runtime/blastbench');(root/'runtime/blastbench').chmod(0o755)
    bundles=[b for b in exe.parent.glob('*.bundle') if 'test' not in b.name.lower()]
    for bundle in bundles:shutil.copytree(bundle,root/'runtime'/bundle.name,ignore=skip_sealed)
    shutil.copyfile(here/'device.swift',root/'runtime/device.swift')
    compile_command=['swiftc','-O','-warnings-as-errors','-target',platform.machine()+'-apple-macos15.0',str(root/'runtime/device.swift'),'-o',str(root/'runtime/device-info')]
    compiled=subprocess.run(compile_command,capture_output=True,text=True,timeout=120)
    (root/'logs/device-compile.log').write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode:raise RuntimeError('device query compile failed; no numerical case launched')
    before=json.loads(subprocess.check_output([str(root/'runtime/device-info')],text=True,timeout=60))
    atomic(root/'device-before.json',before)
    (root/'runtime-pins').mkdir()
    runtime_pins=[]
    for path in [Path(sys.executable).resolve(),Path(np._core._multiarray_umath.__file__).resolve()]:
        copied=root/'runtime-pins'/path.name;shutil.copyfile(path,copied)
        runtime_pins.append(dict(original=str(path),snapshot=str(copied),sha256=digest(copied)))
    dynamic=subprocess.check_output(['otool','-L',str(exe)],text=True)
    (root/'runtime-dependencies.txt').write_text(dynamic)
    assert all(line.strip().startswith(('/System/','/usr/lib/')) for line in dynamic.splitlines()[1:]),'local project dependency needs an explicit freeze'
    environment=dict(pythonExecutable=sys.executable,pythonVersion=sys.version,numpyVersion=np.__version__,runtimeBytePins=runtime_pins,deviceContextBefore=before,scope='Selected source/runtime/resource and Python/NumPy-core byte pins, not a hermetic OS/driver/dependency environment; sealed material and test-only bundles excluded')
    runtime={str(p.relative_to(root/'runtime')):digest(p) for p in sorted((root/'runtime').rglob('*')) if p.is_file()}
    analysis={str(p.relative_to(root/'analysis')):digest(p) for p in sorted((root/'analysis').rglob('*')) if p.is_file()}
    # Original resource pins also guard a generated Bundle.module absolute-path fallback.
    resources={str(p):digest(p) for b in bundles for p in safe_files(b) if p.suffix=='.metal'}
    report=dict(status='running',revision=revision,worktreeDirty=dirty,plan=plan(),frozenSources=frozen,runtimeSHA256=runtime,originalResourceSHA256=resources,analysisSHA256=analysis,environment=environment,commands=[])
    report['controllerProcess']=dict(pid=os.getpid(),boot=boot_id(),identity=process_snapshot(os.getpid()))
    def save():atomic(root/'run.json',report)
    env=clean_env(dict(slotEnvironment={},revisionObservedAtInit=revision,worktreeDirtyAtInit=dirty))
    save()
    try:
        for job in report['plan']['jobs']:
            assert all(digest(x['path'])==x['sha256'] for x in frozen)
            assert all(digest(root/'runtime'/name)==sha for name,sha in runtime.items())
            assert all(digest(name)==sha for name,sha in resources.items())
            assert all(digest(root/'analysis'/name)==sha for name,sha in analysis.items())
            output=root/'cases'/job['label']
            command=[str(Path.home()/'.local/bin/gpu-slot'),'--mem','2',str(root/'runtime/blastbench'),*job['arguments'],'--out',str(output)]
            entry=dict(label=job['label'],command=command,status='running');report['commands'].append(entry)
            with (root/'logs'/(job['label']+'.log')).open('wb') as log:
                child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
                identity=process_snapshot(child.pid)
                report['liveProcess']=dict(pid=child.pid,pgid=child.pid,boot=boot_id(),birth=identity['birth'] if identity else None,label=job['label'])
                save()
                # This is a declared execution budget, not an observation/retry timeout.
                try:
                    entry['returncode']=child.wait(timeout=80*60)
                except subprocess.TimeoutExpired:
                    entry['executionBudgetExceeded']=True
                    current=process_snapshot(child.pid)
                    if child.poll() is None and identity and current and current['birth']==identity['birth'] and boot_id()==report['liveProcess']['boot']:
                        os.killpg(child.pid,signal.SIGTERM)
                        try:entry['returncode']=child.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            current=process_snapshot(child.pid)
                            if not current or current['birth']!=identity['birth']:raise RuntimeError('owned process identity no longer proven')
                            os.killpg(child.pid,signal.SIGKILL)
                            entry['returncode']=child.wait(timeout=30)
                    else:raise RuntimeError('execution budget ended but exact live owner identity is not proven')
                assert not group_alive(child.pid),'owned descendant remains live; inspect exact group'
                entry['terminalProcess']=report.pop('liveProcess');entry['status']='complete' if entry['returncode']==0 else 'failed'
            entry['retainedFiles']={str(p.relative_to(output)):dict(sha256=digest(p),bytes=p.stat().st_size) for p in sorted(output.rglob('*')) if p.is_file()}
            if entry['returncode']==0:
                produced=json.loads((output/'runs.json').read_text())
                assert len(produced['cases'])==1 and produced['cases'][0]['case']==job['case'],'case selector contract broken'
                assert len(produced['cases'][0]['runs'])==3,'observation mode contract broken'
            save()
        assert len(report['commands'])==432
        report['status']='complete' if all(x['returncode']==0 for x in report['commands']) else 'complete-with-failures'
        after=json.loads(subprocess.check_output([str(root/'runtime/device-info')],text=True,timeout=60));atomic(root/'device-after.json',after)
        report['deviceContextBeforeAfterEqual']=before==after
    except BaseException as error:
        report['status']='failed';report['error']=repr(error);raise
    finally:save()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['plan','run']);parser.add_argument('--out')
    args=parser.parse_args()
    if args.mode=='plan':
        content=json.dumps(plan(),indent=2)+'\n'
        if args.out:Path(args.out).write_text(content)
        else:print(content)
    else:run()
