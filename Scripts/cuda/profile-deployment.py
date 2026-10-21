#!/usr/bin/env python3
"""Profile complete SSH deployments with a primed optional PTX cache and unchanged gates.

Plan JSON is a list of {name, input, reference, retrieval: all|dataset}. Every job runs
three alternating uncached/cached pairs. No accepted datasets are published. Outputs
must be new; partial reports remain explicitly incomplete after failure/interruption.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import statistics
import subprocess
import time
from remote import deploy
from compare import compare as compare_fields
from compare_dataset import compare as compare_dataset


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''): h.update(block)
    return h.hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('host');p.add_argument('plan',type=Path)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--cache-dir',required=True,help='new, dedicated remote cache directory')
    p.add_argument('--context',required=True)
    a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',a.host):p.error('invalid host alias')
    if not re.fullmatch(r'[A-Za-z0-9_./-]+',a.cache_dir) or '..' in Path(a.cache_dir).parts:p.error('invalid cache path')
    if a.out.exists():p.error('output must be new')
    plan=json.loads(a.plan.read_text())
    if not plan or len({j['name'] for j in plan})!=len(plan):p.error('empty plan or duplicate names')
    for j in plan:
        if not re.fullmatch(r'[A-Za-z0-9_-]+',j['name']) or j['retrieval'] not in ('all','dataset'):p.error('invalid plan job')
        if not Path(j['input'],'job.json').is_file() or not Path(j['reference']).is_dir():p.error('missing input or reference')
    ssh=['ssh','-o','BatchMode=yes',a.host]
    def snapshot():
        r=subprocess.run(ssh+['if test -d bombcad-ml/lock; then echo LOCKED; cat bombcad-ml/lock/owner; else echo FREE; fi; nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used --format=csv,noheader,nounits'],capture_output=True,text=True,check=True,timeout=20)
        lines=r.stdout.strip().splitlines()
        if not lines or lines[0]!='FREE':raise RuntimeError('PC GPU reserved; stop before deployment')
        utilization=int(lines[-1].split(',')[-2].strip())
        if utilization>5:raise RuntimeError('PC GPU not quiet before/after deployment: '+r.stdout)
        return r.stdout
    # Refuse silently reusing a previously populated cache in a purported priming experiment.
    subprocess.run(ssh+['test ! -e '+shlex.quote(a.cache_dir)],check=True,timeout=20)
    a.out.mkdir(parents=True)
    report={'status':'running','context':a.context,'plan':plan,'cacheDirectory':a.cache_dir,
            'scope':__doc__,'rows':[],'sourceFilesSHA256':{n:digest(Path(__file__).with_name(n)) for n in ('profile-deployment.py','remote.py','run.py','job.py','compile.py')}}
    def save():
        temporary=a.out/'profile.tmp'
        temporary.write_text(json.dumps(report,indent=2)+'\n');temporary.replace(a.out/'profile.json')
    save()
    try:
        report['before']=snapshot()
        first=plan[0]
        result=deploy(a.host,first['input'],a.out/'prime',dataset_only=first['retrieval']=='dataset',cache_dir=a.cache_dir)
        report['prime']={'result':result,'deployment':json.loads((a.out/'prime/deployment.json').read_text())}
        save()
        for job in plan:
            baseline=None
            for repetition in range(3):
                for mode in (('uncached','cached') if repetition%2==0 else ('cached','uncached')):
                    before=snapshot();target=a.out/f"{job['name']}-{repetition}-{mode}"
                    result=deploy(a.host,job['input'],target,dataset_only=job['retrieval']=='dataset',cache_dir=a.cache_dir if mode=='cached' else None)
                    after=snapshot();deployment=json.loads((target/'deployment.json').read_text())
                    start=time.perf_counter()
                    if job['retrieval']=='dataset':
                        gate=compare_dataset(job['reference'],target/'dataset')
                    else:gate=compare_fields(job['reference'],target)
                    hashes={str(f.relative_to(target)):digest(f) for f in target.rglob('*') if f.is_file() and f.suffix in ('.bin','.npy')}
                    # Also verify raw numerical fields and timesteps retained on the PC, including dataset-only jobs.
                    remote=deployment['directory']+'/out'
                    raw=subprocess.check_output(ssh+['cd '+shlex.quote(remote)+' && sha256sum *.bin *.npy'],text=True,timeout=30)
                    remote_hashes={line.split()[1]:line.split()[0] for line in raw.splitlines()}
                    if baseline is None:baseline=remote_hashes
                    equal=remote_hashes==baseline
                    row={'job':job['name'],'repetition':repetition,'mode':mode,'result':result,
                         'deployment':deployment,'before':before,'after':after,'comparison':gate,
                         'localNumericalSHA256':hashes,'remoteNumericalSHA256':remote_hashes,
                         'bitIdenticalAcrossModesAndRepeats':equal,'comparisonAndHashSeconds':time.perf_counter()-start}
                    report['rows'].append(row);save()
                    print(job['name'],repetition,mode,round(deployment['totalSecondsBeforeReceipt'],3),'gate',gate['passed'],'identical',equal,flush=True)
                    if not gate['passed'] or not equal:raise RuntimeError('numerical acceptance or repeat equality failed')
        report['medians']={}
        for job in plan:
            report['medians'][job['name']]={}
            for mode in ('uncached','cached'):
                rows=[r for r in report['rows'] if r['job']==job['name'] and r['mode']==mode]
                report['medians'][job['name']][mode]={
                    'deploymentSeconds':statistics.median(r['deployment']['totalSecondsBeforeReceipt'] for r in rows),
                    'solverSeconds':statistics.median(r['result']['wallSeconds'] for r in rows),
                    'phases':{key:statistics.median(r['deployment']['timings'][key] for r in rows) for key in rows[0]['deployment']['timings']}}
        report['status']='complete';report['after']=snapshot();save()
    except BaseException as error:
        report['status']='failed';report['error']=repr(error);save();raise


if __name__=='__main__':main()
