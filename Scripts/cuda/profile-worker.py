#!/usr/bin/env python3
"""Compare two isolated CUDA worker files on identical jobs under the shared GPU lock.

Run on the PC with its existing CUDA Python environment. By default all runs share one
interpreter; --fresh-process includes a new Python/PyTorch process each time. Compilation
and worker setup are included in totalSeconds, measured with Linux CLOCK_MONOTONIC_RAW;
solver time is the worker's wallSeconds. Set both cache-directory options for symmetric
warm-cache comparisons, or only the candidate option for a cache experiment. Executed-worker
provenance must match each explicit variant. Inputs and output folders must be explicit.
This does not deploy or alter installed workers.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import sys
import subprocess
import time


TIMING_CLOCK = 'clock_gettime(CLOCK_MONOTONIC_RAW)'


def elapsed_time():
    if not hasattr(time, 'CLOCK_MONOTONIC_RAW'):
        raise RuntimeError('CUDA profiling requires CLOCK_MONOTONIC_RAW')
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


def module(path, name):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1048576),b''): h.update(chunk)
    return h.hexdigest()



def run_fresh(command,timeout=600):
    # A drained pipe wakes communicate on output/EOF instead of waiting solely by timeout polling.
    # subprocess.run kills and reaps the owned child if the deadline expires.
    return subprocess.run(command,check=True,stdout=subprocess.PIPE,timeout=timeout)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--candidate',type=Path,required=True)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--jobs',type=Path,nargs='+',required=True)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--lock',type=Path,required=True)
    p.add_argument('--lock-helper',type=Path,required=True)
    p.add_argument('--fresh-process',action='store_true',help='include a new Python/PyTorch process for every run')
    p.add_argument('--baseline-cache-dir',type=Path,help='pass an opt-in PTX cache to baseline for symmetric warm-cache comparisons')
    p.add_argument('--candidate-cache-dir',type=Path,help='pass an opt-in PTX cache only to candidate')
    p.add_argument('--repetitions',type=int,default=3)
    a=p.parse_args()
    if a.repetitions<3: p.error('at least three repetitions required')
    if a.out.exists(): p.error('output must be new')
    lock=module(a.lock_helper,'profile_lock')
    if not lock.acquire(str(a.lock),'bounded CUDA worker profile',lock.boot_id()):
        raise SystemExit('GPU held by another job')
    try:
        import torch
        torch.cuda.init()
        def snapshot():
            r=subprocess.run(['nvidia-smi','--query-gpu=name,driver_version,memory.used,utilization.gpu','--format=csv'],capture_output=True,text=True,timeout=10)
            return {'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
        before=snapshot()
        a.out.mkdir(parents=True)
        workers={k:module(path,k) for k,path in [('baseline',a.baseline),('candidate',a.candidate)]}
        rows=[]
        for job in a.jobs:
            for repetition in range(a.repetitions):
                pair={}
                order=['baseline','candidate'] if repetition%2==0 else ['candidate','baseline']
                for name in order:
                    out=a.out/f'{job.name}-{repetition}-{name}'
                    start=elapsed_time()
                    cache=a.candidate_cache_dir if name=='candidate' else a.baseline_cache_dir
                    kwargs={'cache_dir':cache} if cache else {}
                    if a.fresh_process:
                        worker_path=a.baseline if name=='baseline' else a.candidate
                        command=[sys.executable,str(worker_path),str(job),'--source',str(a.source),'--out',str(out)]
                        if kwargs: command += ['--cache-dir',str(cache)]
                        run_fresh(command)
                        result=json.loads((out/'result.json').read_text())
                    else:
                        result=workers[name].run(job,a.source,out,**kwargs)
                    elapsed=elapsed_time()-start
                    worker_path=a.baseline if name=='baseline' else a.candidate
                    if result.get('workerFilesSHA256',{}).get('run.py')!=digest(worker_path):
                        raise RuntimeError('executed worker provenance differs; no accepted profile')
                    hashes={str(p.relative_to(out)):digest(p) for p in out.rglob('*') if p.is_file() and p.suffix in ('.bin','.npy')}
                    row={'job':job.name,'repetition':repetition,'worker':name,'totalSeconds':elapsed,
                         'solverSeconds':result['wallSeconds'],'solverTimingClock':result.get('timingClock','legacy adjusted host monotonic'),
                         'clockAudit':result.get('clockAudit'),'steps':result['steps'],
                         'elapsedSimulationTime':result['elapsedSimulationTime'],'hashes':hashes,
                         'timings':result.get('timings')}
                    rows.append(row);pair[name]=row
                    print(job.name,repetition,name,round(elapsed,3),flush=True)
                if pair['baseline']['hashes']!=pair['candidate']['hashes']:
                    raise RuntimeError('full outputs or timestep histories differ; no accepted profile')
        summaries=[]
        for job in a.jobs:
            values={k:[r for r in rows if r['job']==job.name and r['worker']==k] for k in workers}
            summaries.append({'job':job.name,**{k:{'medianTotalSeconds':statistics.median(r['totalSeconds'] for r in v),
                'medianSolverSeconds':statistics.median(r['solverSeconds'] for r in v)} for k,v in values.items()}})
        report={'format':'bombcad-worker-profile-1','timingClock':TIMING_CLOCK,'device':torch.cuda.get_device_name(),
                'profilerSHA256':digest(Path(__file__)),
                'freshProcessObserver':'drained stdout/EOF readiness; hard timeout; residual exit observation included' if a.fresh_process else None,
                'baselineCacheDir':str(a.baseline_cache_dir) if a.baseline_cache_dir else None,
                'candidateCacheDir':str(a.candidate_cache_dir) if a.candidate_cache_dir else None,
                'torch':torch.__version__,'cuda':torch.version.cuda,'before':before,'after':snapshot(),
                'scope':('fresh Python process per run' if a.fresh_process else 'one interpreter')+'; alternating order; total includes compile/setup/output, excludes deployment and retrieval; solver time excludes setup/output',
                'sourceSHA256':digest(a.source),'workerSHA256':{k:digest(path) for k,path in [('baseline',a.baseline),('candidate',a.candidate)]},
                'jobs':{str(j):digest(j/'job.json') for j in a.jobs},'rows':rows,'summaries':summaries,
                'allOutputsAndTimestepsBitIdentical':True}
        (a.out/'profile.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(summaries,indent=2))
    finally:
        lock.release(str(a.lock))


if __name__=='__main__': main()
