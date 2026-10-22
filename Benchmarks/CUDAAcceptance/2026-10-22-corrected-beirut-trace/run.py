"""One corrected-input receiver study; fail closed on observer parity or provenance."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

REPO=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
BASE=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')
ROOT=BASE.parent/'2026-10-22-corrected-beirut-trace'
COLUMN=187747


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


def main():
    sys.path.insert(0,str(REPO/'Scripts/cuda'))
    q=module('queue',REPO/'Scripts/cuda/field-queue.py')
    phase=module('phase',BASE/'analysis/cuda/diagnose-phase.py')
    from generate import generate
    frozen=q.read(BASE/'run.json')
    job=next(j for j in frozen['jobs'] if j['id']=='beirut-p0-1')
    baseline=BASE/'cases/beirut-p0-1/metal'
    remote=q.read(BASE/'recovery/remote-inventory.json')['beirut-p0-1/current']
    assert hashlib.sha256(generate().encode()).hexdigest()==frozen['generatedSourceSHA256']
    for name in ['run.py','job.py','compile.py','trace_columns.py']:
        assert q.digest(REPO/'Scripts/cuda'/name)==frozen['frozenFiles']['analysis/cuda/'+name]['sha256']
    ROOT.mkdir(exist_ok=False);(ROOT/'analysis').mkdir()
    for path in [Path(__file__),HERE/'plan.md']:
        shutil.copyfile(path,ROOT/'analysis'/path.name)
    pins={str(BASE/n):v['sha256'] for n,v in frozen['frozenFiles'].items() if n.startswith(('runtime/','inputs/'))}
    pins.update({str(p):q.digest(p) for p in (REPO/'Scripts/cuda').glob('*.py')})
    pins[str(REPO/'Scripts/ml/remote-train.py')]=q.digest(REPO/'Scripts/ml/remote-train.py')
    pins[str(ROOT/'analysis/run.py')]=q.digest(__file__)
    pins[str(ROOT/'analysis/plan.md')]=q.digest(HERE/'plan.md')
    for p in [BASE/'analysis/cuda/diagnose-phase.py',BASE/'run.json',BASE/'recovery/remote-inventory.json']:
        pins[str(p)]=q.digest(p)
    input_folder=BASE/'cases/beirut-p0-1/input'
    physical=q.read(input_folder/'job.json')
    for name in ['job.json',*physical['files']]:pins[str(input_folder/name)]=q.digest(input_folder/name)
    for p in baseline.glob('*.npy'):pins[str(p)]=q.digest(p)
    report=dict(status='running',scope=__doc__,controllerPID=os.getpid(),boot=q.boot_id(),
        baselineRevision=frozen['revision'],publicationRevision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),
        column=COLUMN,pins=pins,commands=[],metal=[],baselineRemote=remote['remote'])
    def save():q.atomic(ROOT/'run.json',report)
    def verify():
        for p,h in pins.items():assert q.digest(p)==h,'Consumed file changed: '+p
    env=q.clean_env(dict(slotEnvironment={},revisionObservedAtInit=frozen['revision'],worktreeDirtyAtInit=False))
    for key in ['PACKAGE_RESOURCE_BUNDLE_PATH','PACKAGE_RESOURCE_BUNDLE_URL']:env.pop(key,None)
    def run(command,label):
        verify()
        with (ROOT/(label+'.log')).open('wb') as log:
            p=subprocess.Popen(command,cwd=REPO,stdout=log,stderr=subprocess.STDOUT,env=env,start_new_session=True)
            entry=dict(label=label,pid=p.pid,pgid=p.pid,identity=q.process_snapshot(p.pid),command=command)
            report['liveProcess']=entry;save();entry['returncode']=p.wait()
        assert not q.group_alive(p.pid),'Owned descendant remains live'
        report['commands'].append(entry);report.pop('liveProcess');save();verify()
        assert entry['returncode']==0,(label,entry['returncode'])
    save()
    try:
        verify()
        args=[];i=0
        while i<len(job['arguments']):
            key=job['arguments'][i];i+=1
            if key in ['--out','--initial-state-diagnostic','--cuda-source']:i+=1;continue
            args.append(key)
        original={p.name:q.digest(p) for p in baseline.glob('*.npy')}
        for mode in ['plain','pressure']:
            out=ROOT/mode
            extra=[] if mode=='plain' else ['--trace-columns',str(COLUMN),'--trace-pressure']
            run([str(Path.home()/'.local/bin/gpu-slot'),'--mem',str(job['run']['estimate']['memGB']),str(BASE/'runtime/scenebench'),
                 *args,*extra,'--diagnostic-state-hashes','--out',str(out)],'metal-'+mode)
            meta=q.read(out/'meta.json');assert meta['stable'] is True
            actual={p.name:q.digest(p) for p in out.glob('*.npy') if p.name!='pressure-trace.npy'}
            assert actual==original,'Metal dataset differs from corrected baseline'
            state=q.read(out/'diagnostic-state-hashes.json')
            report['metal'].append(dict(mode=mode,datasetSHA256=actual,state=state,meta=meta));save()
        assert report['metal'][0]['state']==report['metal'][1]['state'],'Metal recorder changed hashed state'
        m,d=phase.load(ROOT/'pressure');summary=phase.summarize(m,d)
        q.atomic(ROOT/'pressure/replay.json',summary)
        assert all(c['exactAccumulationPolicies'] for c in summary['columns']),'Metal seeded replay differs'
        report['metalObserverParity']=True;save()
        # The deployment helper verifies generated source, worker and diagnostic provenance.
        run([sys.executable,'-B',str(REPO/'Scripts/cuda/remote.py'),'bombcad-pc',str(input_folder),
             '--out',str(ROOT/'cuda'),'--trace-columns',str(COLUMN),'--diagnostics-only',
             '--cache-dir','bombcad-cuda/ptx-cache'],'cuda-pressure')
        deployment=q.read(ROOT/'cuda/deployment.json');new=deployment['directory']
        assert q.read(ROOT/'cuda/result.json')['sourceSHA256']==frozen['generatedSourceSHA256']
        script="""import pathlib,hashlib,json
root=pathlib.Path.home()
def files(name):
 p=root/name/'out'
 return {str(q.relative_to(p)):dict(sha256=hashlib.sha256(q.read_bytes()).hexdigest(),bytes=q.stat().st_size) for q in sorted(p.rglob('*')) if q.is_file() and q.suffix in ('.bin','.npy')}
a=files(OLD);b=files(NEW)
assert a and all(b.get(k)==v for k,v in a.items())
assert set(b)-set(a)=={'trace.npy'}
print(json.dumps(dict(baseline=a,traced=b,baselineDirectory=OLD,tracedDirectory=NEW,boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip())))
""".replace('OLD',repr(remote['remote'])).replace('NEW',repr(new))
        proof=json.loads(subprocess.check_output(['ssh','-o','BatchMode=yes','bombcad-pc','python3 -c '+shlex.quote(script)],text=True))
        for n,pin in remote['files'].items():
            if n.startswith('out/') and n.endswith(('.bin','.npy')):assert proof['baseline'][n[4:]]==pin
        q.atomic(ROOT/'cuda-numeric-parity.json',proof)
        m,d=phase.load(ROOT/'cuda');summary=phase.summarize(m,d)
        q.atomic(ROOT/'cuda/replay.json',summary)
        assert all(c['float32Replay']['recorderValuesDifferent']==0 for c in summary['columns']),'CUDA replay differs'
        report.update(status='complete',metalObserverParity=True,cudaNumericAndTimestepsParity=True,
            allConsumedPinsUnchanged=True,allOwnedGroupsTerminal=True,deployment=deployment)
        verify();save();print(json.dumps({k:v for k,v in report.items() if k not in ['pins','metal']},indent=2))
    except BaseException as error:
        report.update(status='failed',error=repr(error));save();raise


if __name__=='__main__':main()
