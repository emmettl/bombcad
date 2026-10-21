"""Run the predeclared 144-run acoustic controls once, retaining partial output on failure."""
from pathlib import Path
import hashlib, importlib.util, json, os, shutil, subprocess, sys
repo = Path.cwd()
sys.path.insert(0, str(repo / 'Scripts/cuda'))
spec = importlib.util.spec_from_file_location('queue', repo / 'Scripts/cuda/field-queue.py')
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)
root = Path(os.environ.get('BOMBCAD_DATA', '/Volumes/StudioData/bombcad')) / 'experiments/2026-10-22-acoustic-controls'
root.mkdir(parents=True, exist_ok=False)
exe = Path('.build/release/blastbench').resolve()
paths = [exe, Path(__file__).resolve(), Path(__file__).with_name('plan.md')]
for directory in ['BlastModel', 'BlastCore', 'blastbench']:
    paths += sorted((repo / 'Sources' / directory).rglob('*.swift'))
paths += sorted((repo / 'Sources/BlastCore/Shaders').glob('*.metal'))
paths += [p for b in exe.parent.glob('*.bundle') for p in b.rglob('*.metal')]
pins = {str(p): q.digest(p) for p in paths}
env = q.clean_env(dict(slotEnvironment={}, revisionObservedAtInit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), worktreeDirtyAtInit=True))
commands = []
for policy in ['default','unfused']:
    for cfl in ['0.45','0.225']:
        label=policy+'-cfl'+cfl
        command=[str(Path.home()/'.local/bin/gpu-slot'),'--mem','2',str(exe),'acoustic-phase','--fine','--rounding',policy,'--cfl',cfl,'--out',str(root/label)]
        commands.append(dict(label=label,command=command))
frozen=[]
(root/'sources').mkdir()
for i,(name,digest) in enumerate(pins.items()):
    dst=root/'sources'/f'{i:04d}-{Path(name).name}'
    shutil.copy2(name,dst)
    assert q.digest(dst)==digest
    frozen.append(dict(original=name,path=str(dst),sha256=digest,bytes=dst.stat().st_size))
report = dict(status='running', scope=__doc__, sourceFilesSHA256=pins, commands=commands, frozenSources=frozen, pid=os.getpid(), revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), worktreeDirty=True)
(root / 'candidate.patch').write_bytes(subprocess.check_output(['git', 'diff', '--binary']))
def save(): q.atomic(root / 'run.json', report)
save()
try:
    for item in commands:
        command=item['command']
        with (root/(item['label']+'.log')).open('wb') as log:
            child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
            identity=q.process_snapshot(child.pid)
            report['liveProcess']=dict(pid=child.pid,pgid=child.pid,boot=q.boot_id(),birth=identity['birth'] if identity else None,label=item['label'])
            save()
            item['returncode']=child.wait()
            assert not q.group_alive(child.pid),'owned descendant remains live'
            item['terminalProcess']=report.pop('liveProcess')
            save()
        for name,digest in pins.items():assert q.digest(name)==digest,name
        assert item['returncode']==0,(item['label'],item['returncode'])
    report['status'] = 'complete'
except BaseException as error:
    report['status'] = 'failed'
    report['error'] = repr(error)
    raise
finally:
    report['retainedFiles'] = {str(p.relative_to(root)): dict(sha256=q.digest(p), bytes=p.stat().st_size) for p in sorted(root.rglob('*')) if p.is_file() and p.name != 'run.json' and 'sources' not in p.relative_to(root).parts}
    save()
print(json.dumps({k:v for k,v in report.items() if k not in ['sourceFilesSHA256', 'retainedFiles', 'frozenSources']}, indent=2))
