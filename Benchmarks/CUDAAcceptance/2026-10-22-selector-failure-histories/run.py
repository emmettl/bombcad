"""Four declared expanded observations, each gated on immutable ordinary/old-history bytes."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import numpy as np

from prepare import ROOT,PARENT,load,save,sha


def main():
    prep=load(ROOT/'preparation.json');report_path=ROOT/'capture.json'
    assert not report_path.exists(),'Observe existing stage; no numerical retry'
    helpers=PARENT/'analysis/qhelpers';sys.path.insert(0,str(helpers))
    spec=importlib.util.spec_from_file_location('qualified_queue',helpers/'field-queue.py')
    q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)
    pins=dict(prep['pins']);pins[str(Path(__file__))]=sha(__file__)
    report=dict(status='running',runtimeRevision=prep['runtimeRevision'],pins=pins,consumed=prep['consumed'],
        controllerPID=os.getpid(),boot=q.boot_id(),sourceSHA256=sha(__file__),rows=[],commands=[])
    def persist():q.atomic(report_path,report)
    def verify():
        for mapping in [pins,prep['consumed']]:
            for p,h in mapping.items():assert sha(p)==h,p
    env=q.clean_env(dict(slotEnvironment={},revisionObservedAtInit=prep['runtimeRevision'],worktreeDirtyAtInit=False))
    for k in ['PACKAGE_RESOURCE_BUNDLE_PATH','PACKAGE_RESOURCE_BUNDLE_URL']:env.pop(k,None)
    deadline=time.monotonic()+5400;persist()
    try:
        for planned in prep['rows']:
            name,mode=planned['id'],planned['mode'];parent=Path(planned['parentFolder'])
            folder=ROOT/mode/name;folder.parent.mkdir(exist_ok=True);assert not folder.exists()
            command=[];it=iter(planned['command'])
            for arg in it:
                if arg=='--out':next(it)
                elif arg=='--trace-columns':next(it);command.extend([arg,','.join(map(str,planned['columns']))])
                else:command.append(arg)
            command.extend(['--out',str(folder)]);verify()
            with (ROOT/(mode+'-'+name+'.log')).open('xb') as log:
                proc=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
                identity=q.process_snapshot(proc.pid)
                entry=dict(pid=proc.pid,identity=identity,boot=q.boot_id(),command=command)
                report['liveProcess']=entry;persist()
                def same():
                    actual=q.process_snapshot(proc.pid)
                    return actual is not None and identity is not None and entry['boot']==q.boot_id() and actual['birth']==identity['birth'] and actual['command']==identity['command']
                try:code=proc.wait(timeout=max(1,deadline-time.monotonic()))
                except subprocess.TimeoutExpired:
                    assert same();os.killpg(proc.pid,signal.SIGTERM)
                    try:code=proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        assert same();os.killpg(proc.pid,signal.SIGKILL);code=proc.wait()
                    entry['timedOut']=True
            entry.update(returncode=code,ownedGroupTerminal=not q.group_alive(proc.pid))
            report['commands'].append(entry);report.pop('liveProcess');persist()
            row=dict(id=name,mode=mode,status='worker-failed',returncode=code);report['rows'].append(row);persist()
            assert code==0 and entry['ownedGroupTerminal']
            ordinary={n:sha(folder/n)==sha(parent/n) for n in ['inputs.npy','mask.npy','targets.npy','diagnostic-state-hashes.json','clock-inputs.bin','clock-inputs.json']}
            histories={}
            for stem in ['pressure-trace','pressure-inputs']:
                ainfo,binfo=load(folder/(stem+'.json')),load(parent/(stem+'.json'))
                assert set(ainfo['columns'])==set(planned['columns'])
                positions=[ainfo['columns'].index(c) for c in binfo['columns']]
                a,b=np.load(folder/(stem+'.npy')),np.load(parent/(stem+'.npy'))
                selected=a[:,positions,:]
                axes={k:ainfo[k]==binfo[k] for k in ['steps','times','fields']}
                histories[stem]=dict(priorColumns=binfo['columns'],allOldWordsExact=np.array_equal(selected.view('<u4'),b.view('<u4')),
                    axesExact=axes,newShape=list(a.shape),oldShape=list(b.shape))
            new_info=load(folder/'pressure-inputs.json');old_info=load(parent/'pressure-inputs.json')
            positions=[new_info['columns'].index(c) for c in old_info['columns']]
            a,b=np.load(folder/'pressure-input-endpoints.npy'),np.load(parent/'pressure-input-endpoints.npy')
            endpoints=np.array_equal(a[:,positions,:].view('<u4'),b.view('<u4'))
            if mode=='selector':assert (folder/'step-selector.json').read_bytes()==(parent/'step-selector.json').read_bytes()
            passed=all(ordinary.values()) and endpoints and all(r['allOldWordsExact'] and all(r['axesExact'].values()) for r in histories.values())
            row.update(status='expanded-parity-pass' if passed else 'expanded-parity-failed',ordinaryExact=ordinary,
                oldHistories=histories,oldEndpointsExact=endpoints,
                files={p.name:dict(sha256=sha(p),bytes=p.stat().st_size) for p in folder.iterdir() if p.is_file()})
            persist();assert passed,'Retained expanded observer failure; no retry or capture adjustment'
        verify();report.update(status='complete-all-outcomes',allFourExpandedGatesPass=len(report['rows'])==4,
            allOwnedGroupsTerminal=all(r['ownedGroupTerminal'] for r in report['commands']))
    except BaseException as e:report.update(status='stopped',error=repr(e));persist();raise
    persist();print('Four expanded captures terminal0; all ordinary/clock/old-history/endpoint gates pass')


if __name__=='__main__':main()
