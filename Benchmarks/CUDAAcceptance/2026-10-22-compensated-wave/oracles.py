"""Run every unique independent oracle input once; retain aliases and failed attempts."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('owned',HERE/'run.py');owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)


def main(root,audit_dir):
    root=Path(root);audit_dir=Path(audit_dir)
    source=json.loads((root/'run.json').read_text())
    for name,digest in source['analysisSHA256'].items():assert owned.digest(HERE/name)==digest
    audit=json.loads((audit_dir/'audit.json').read_text())
    jobs={}
    for row in audit['rows']:
        if row['status']=='audited':jobs.setdefault(row['oracleKey'],[]).append(row['label'])
    target=audit_dir/'oracles';target.mkdir(exist_ok=False)
    report=dict(status='running',jobs=[],unavailableCases=[dict(label=r['label'],status=r['status']) for r in audit['rows'] if r['status']!='audited'],parallelWorkers=4)
    lock=threading.Lock();boot=owned.boot_id()
    def save():owned.atomic(audit_dir/'oracle-run.json',report)
    save()
    def execute(item):
        key,aliases=item;input_path=audit_dir/'oracle-inputs'/(key+'.npz')
        entry=dict(key=key,aliases=aliases,inputSHA256=owned.digest(input_path),status='running')
        command=[sys.executable,str(HERE/'reference-worker.py'),str(HERE/'planar_euler.py'),str(input_path),str(target/(key+'.npz')),str(target/(key+'.json'))]
        entry['command']=command
        env=dict(os.environ,OPENBLAS_NUM_THREADS='1',OMP_NUM_THREADS='1')
        with (target/(key+'.log')).open('wb') as log:
            child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env=env)
            identity=owned.process_snapshot(child.pid)
            entry['process']=dict(pid=child.pid,pgid=child.pid,boot=boot,birth=identity['birth'] if identity else None)
            with lock:report['jobs'].append(entry);save()
            try:status=child.wait(timeout=20*60)
            except subprocess.TimeoutExpired:
                entry['executionBudgetExceeded']=True;current=owned.process_snapshot(child.pid)
                if not identity or not current or current['birth']!=identity['birth'] or owned.boot_id()!=boot:raise RuntimeError('live owner identity not proven')
                os.killpg(child.pid,signal.SIGTERM)
                try:status=child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    current=owned.process_snapshot(child.pid)
                    if not current or current['birth']!=identity['birth']:raise RuntimeError('live owner identity changed')
                    os.killpg(child.pid,signal.SIGKILL);status=child.wait(timeout=30)
        assert not owned.group_alive(child.pid),'live owned oracle descendant; do not relaunch'
        assert owned.digest(input_path)==entry['inputSHA256']
        with lock:
            entry.update(returncode=status,status='complete' if status==0 else 'failed',terminal=True)
            entry['retainedFiles']={p.name:dict(sha256=owned.digest(p),bytes=p.stat().st_size) for p in target.glob(key+'.*') if p.is_file()}
            save()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(execute,sorted(jobs.items())))
        report['status']='complete' if all(j['returncode']==0 for j in report['jobs']) else 'complete-with-failures'
    except BaseException as error:report.update(status='failed',error=repr(error));raise
    finally:save()
    print(json.dumps(dict(status=report['status'],uniqueJobs=len(jobs),caseAliases=sum(map(len,jobs.values())),unavailableCases=len(report['unavailableCases'])),indent=2))


if __name__=='__main__':main(*sys.argv[1:])
