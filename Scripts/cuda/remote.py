#!/usr/bin/env python3
"""Deploy the generated backend over SSH, run one exported job, retrieve its results.

Example: python3 Scripts/cuda/remote.py bombcad-pc /path/to/job --out /path/to/result
The existing host Python CUDA environment is used; nothing is installed system-wide.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import uuid
from generate import generate
from job import validate


def command(args):
    subprocess.run(args,check=True,stdin=subprocess.DEVNULL)


def deploy(host,job,out,python='bombcad-ml/venv/bin/python',dataset_only=False,cache_dir=None,trace_columns=None,diagnostics_only=False,full_grid_cooling=False):
    if diagnostics_only and (dataset_only or not trace_columns):
        raise ValueError('diagnostics-only requires traces and excludes dataset-only')
    if dataset_only and trace_columns:
        raise ValueError('trace retrieval requires full output, not dataset-only')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',host):
        raise ValueError('use a configured SSH host alias')
    if not re.fullmatch(r'[A-Za-z0-9_./-]+',python) or '..' in Path(python).parts:
        raise ValueError('invalid remote Python path')
    if cache_dir is not None and (not re.fullmatch(r'[A-Za-z0-9_./-]+',str(cache_dir)) or '..' in Path(cache_dir).parts):
        raise ValueError('invalid remote cache path')
    job=Path(job).resolve();out=Path(out).resolve()
    if out.exists():raise ValueError('local output already exists')
    source=generate();meta,_=validate(job,source)
    version=hashlib.sha256(source.encode()).hexdigest()[:16]
    root=f'bombcad-cuda/{version}'
    ident=uuid.uuid4().hex
    remote=f'{root}/jobs/{ident}'
    local=Path(__file__).resolve().parent
    def ssh(text):command(['ssh','-o','BatchMode=yes',host,text])
    with tempfile.TemporaryDirectory(prefix='bombcad-cuda-deploy-') as temp:
        staging=Path(temp)/'worker';staging.mkdir()
        for name in ('run.py','job.py','compile.py','trace_columns.py'):
            shutil.copyfile(local/name,staging/name)
        shutil.copyfile(local.parent/'ml/remote-train.py',staging/'remote-train.py')
        (staging/'solver.cu').write_text(source)
        ssh('mkdir -p '+shlex.quote(remote))
        command(['scp','-r',str(staging),f'{host}:{remote}/worker'])
    # The explicit job directory, and only its manifest-listed files, are transferred.
    with tempfile.TemporaryDirectory(prefix='bombcad-cuda-input-') as temp:
        staging=Path(temp)/'input';staging.mkdir()
        for name in ['job.json',*meta['files'],*meta.get('dataset',{})]:
            shutil.copyfile(job/name,staging/name)
        # Initial fields are mostly still air: compression avoids sending gigabytes of repeats.
        command(['scp','-C','-r',str(staging),f'{host}:{remote}/input'])
    worker=f'{remote}/worker/run.py'
    args=[python,worker,f'{remote}/input','--source',f'{remote}/worker/solver.cu','--out',f'{remote}/out',
          '--lock','bombcad-ml/lock']
    if full_grid_cooling: args += ['--full-grid-cooling']
    if trace_columns: args += ['--trace-columns',','.join(str(i) for i in trace_columns)]
    if cache_dir is not None: args += ['--cache-dir',str(cache_dir)]
    ssh(' '.join(shlex.quote(x) for x in args))
    out.parent.mkdir(parents=True,exist_ok=True)
    if diagnostics_only:
        out.mkdir()
        for name in ('trace.npy','trace.json','result.json'):
            command(['scp',f'{host}:{remote}/out/{name}',str(out/name)])
    elif dataset_only:
        out.mkdir()
        command(['scp','-r',f'{host}:{remote}/out/dataset',str(out/'dataset')])
        command(['scp',f'{host}:{remote}/out/result.json',str(out/'result.json')])
    else:
        command(['scp','-r',f'{host}:{remote}/out',str(out)])
    report=json.loads((out/'result.json').read_text())
    if report['sourceSHA256']!=hashlib.sha256(source.encode()).hexdigest():
        raise ValueError('returned worker source hash differs')
    expected={name:hashlib.sha256((local/name).read_bytes()).hexdigest() for name in ('run.py','job.py','compile.py')}
    if trace_columns: expected['trace_columns.py']=hashlib.sha256((local/'trace_columns.py').read_bytes()).hexdigest()
    if trace_columns:
        from trace_columns import trace_source
        if report.get('traceColumns')!=trace_columns or report.get('diagnosticSourceSHA256')!=hashlib.sha256((source+trace_source(source)).encode()).hexdigest():
            raise ValueError('returned diagnostic source or columns differ')
    if report.get('workerFilesSHA256')!=expected:
        raise ValueError('deployed worker files differ from this checkout')
    (out/'deployment.json').write_text(json.dumps({'host':host,'directory':remote,'sourceSHA256':report['sourceSHA256']},indent=2)+'\n')
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('host');p.add_argument('job',type=Path)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--python',default='bombcad-ml/venv/bin/python')
    p.add_argument('--diagnostics-only',action='store_true',help='retrieve only requested traces and provenance; retain raw fields on PC')
    p.add_argument('--dataset-only',action='store_true',help='retrieve training arrays and provenance; retain raw fields on the PC')
    from trace_columns import parse_columns
    p.add_argument('--trace-columns',type=parse_columns,help='read-only receiver histories; retrieve without --dataset-only')
    p.add_argument('--full-grid-cooling',action='store_true',help='diagnostic fallback: retain original full-grid cooling work')
    p.add_argument('--cache-dir',help='opt-in remote PTX cache directory, e.g. bombcad-cuda/ptx-cache')
    a=p.parse_args();print(json.dumps(deploy(a.host,a.job,a.out,a.python,a.dataset_only,a.cache_dir,a.trace_columns,a.diagnostics_only,a.full_grid_cooling),indent=2))
