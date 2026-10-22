"""Deploy one declared three-case stage; retain all outcomes without numerical retry."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import uuid

from run_metal import ROOT, HERE, BASE, sha, load


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['baseline', 'capture'])
    mode = parser.parse_args().mode
    if mode == 'capture':
        assert load(ROOT/'baseline/receipt.json')['allBaselineNumericParity']
    prepared = load(ROOT/'cuda-preparation.json')
    for mapping in [prepared['pins'], prepared['consumed']]:
        for p, h in mapping.items():
            assert sha(p) == h, p
    receipt = ROOT/(mode+'-controller.json')
    assert not receipt.exists(), 'Observe this stage rather than duplicating it'
    pack = ROOT/(mode+'-pack')
    pack.mkdir(exist_ok=False)
    shutil.copytree(ROOT/'cuda-variant',pack/'worker')
    shutil.copyfile(HERE/'remote_controller.py',pack/'remote_controller.py')
    old = ROOT.parent/'2026-10-22-phase-pressure-inputs'
    archive = load(HERE.parent/old.name/'archive.json')['files']
    assert sha(old/'run.json')==archive['run.json']['sha256']
    cases=[]
    source_hashes=set()
    for row in load(old/'run.json')['rows']:
        name=row['id']
        proof=old/'cases'/name/'parity-and-endpoints.json'
        result=old/'cases'/name/'result.json'
        for p in [proof,result]:
            assert sha(p)==archive[str(p.relative_to(old))]['sha256']
        source_hashes.add(load(result)['diagnosticSourceSHA256'])
        job=BASE/'cases'/name/'input/job.json'
        assert load(job)['startStep']==0
        base_archive=load(HERE.parent/BASE.name/'pilot-archive.json')['files']
        assert sha(job)==base_archive[str(job.relative_to(BASE))]['sha256']
        cases.append(dict(id=name,physicalInput=row['baselineRemote']+'/input',jobSHA256=sha(job),
            columns=row['columns'],originalNumeric=load(proof)['traced']))
    prior=ROOT.parent/'2026-10-22-clock-selection'
    path=prior/'cuda-own/receipt.json'
    assert sha(path)==load(HERE.parent/prior.name/'archive.json')['manifest']['cuda-own/receipt.json']['sha256']
    assert len(source_hashes)==1
    config=dict(mode=mode,cases=cases,workerSHA256=prepared['workerSHA256'],
        controllerSHA256=sha(pack/'remote_controller.py'),diagnosticSourceSHA256=source_hashes.pop(),
        runtimePins=load(path)['selectedRuntimePins'])
    (pack/'manifest.json').write_text(json.dumps(config,indent=2)+'\n')
    remote='bombcad-cuda/clock-inputs/jobs/'+uuid.uuid4().hex
    analysis=ROOT/'analysis-cuda'
    analysis.mkdir(exist_ok=True)
    source_pins={}
    for p in [Path(__file__).resolve(),HERE/'run_metal.py',HERE/'plan.md']:
        dest_source=analysis/(mode+'-'+p.name)
        shutil.copyfile(p,dest_source)
        source_pins[str(p)]=source_pins[str(dest_source)]=sha(p)
    state=dict(status='deploying',mode=mode,remote=remote,controllerPID=os.getpid(),
        pins={**source_pins,**{str(p):sha(p) for p in pack.rglob('*') if p.is_file()}})

    def save():
        receipt.write_text(json.dumps(state,indent=2)+'\n')

    save()
    subprocess.run(['ssh','-o','BatchMode=yes','bombcad-pc','python3 -c '+shlex.quote(
        'from pathlib import Path; (Path.home()/'+repr(remote)+').mkdir(parents=True,exist_ok=False)')],check=True)
    subprocess.run(['scp','-q','-C','-r',str(pack),'bombcad-pc:'+remote+'/pack'],check=True)
    command=['ssh','-o','BatchMode=yes','bombcad-pc','bombcad-ml/venv/bin/python -B '+
        shlex.quote(remote+'/pack/remote_controller.py')+' '+shlex.quote(remote+'/pack')]
    with (ROOT/(mode+'-ssh.log')).open('xb') as log:
        proc=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        state.update(status='running',localSSHPID=proc.pid,command=command)
        save()
        code=proc.wait()
    state.update(status='terminal',returncode=code)
    save()
    dest=ROOT/mode
    dest.mkdir(exist_ok=False)
    subprocess.run(['scp','-q','bombcad-pc:'+remote+'/pack/receipt.json',str(dest/'receipt.json')],check=True)
    result=load(dest/'receipt.json')
    for row in result['rows']:
        folder=dest/row['id']
        folder.mkdir()
        for name,pin in row['retainedAuxiliary'].items():
            assert Path(name).name==name
            subprocess.run(['scp','-q','bombcad-pc:'+remote+'/pack/cases/'+row['id']+'/'+name,str(folder/name)],check=True)
            assert sha(folder/name)==pin['sha256'] and (folder/name).stat().st_size==pin['bytes']
        if row['returncode']==0:
            names=['targets.npy','firstPhaseImpulse.npy','mask.npy','dt.npy','trace.npy','trace.json',
                'pressure-inputs.npy','pressure-inputs.json','result.json']
            if mode=='capture':names+=['clock-inputs.bin','clock-inputs.json']
            for name in names:
                subprocess.run(['scp','-q','bombcad-pc:'+row['output']+'/'+name,str(folder/name)],check=True)
            for name,pin in row['numericFiles'].items():
                if (folder/name).exists():
                    assert sha(folder/name)==pin['sha256'] and (folder/name).stat().st_size==pin['bytes']
    for p,h in state['pins'].items():
        assert sha(p)==h,p
    print(json.dumps(dict(status=result['status'],mode=mode,allOriginalNumericParity=result.get('allOriginalNumericParity'),
        rows=[{k:r[k] for k in ['id','status','returncode']} for r in result['rows']]),indent=2))
    raise SystemExit(code)


if __name__=='__main__':
    main()
