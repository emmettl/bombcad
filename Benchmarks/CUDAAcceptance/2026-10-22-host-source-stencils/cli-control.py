"""Single-attempt frozen CLI serialization/transparency control; not the scientific matrix."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import numpy as np


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def blocked(name):return 'blind' in name.lower() or 'vasudev' in name.lower()


def main():
    here=Path(__file__).resolve().parent;repo=Path.cwd()
    root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-host-source-cli-control');root.mkdir(parents=True,exist_ok=False)
    (root/'sources').mkdir();(root/'runtime').mkdir();(root/'logs').mkdir()
    selected=[here/'cli-control.py',here/'plan.md',repo/'Package.swift']
    if (repo/'Package.resolved').exists():selected.append(repo/'Package.resolved')
    for module in ['BlastCore','BlastModel','blastbench']:
        for directory,folders,files in os.walk(repo/'Sources'/module):
            folders[:]=[n for n in folders if not blocked(n)]
            selected.extend(Path(directory)/n for n in files if not blocked(n) and Path(n).suffix in ['.swift','.metal'])
    pins=[]
    for i,path in enumerate(sorted(set(selected))):
        copy=root/'sources'/f'{i:04d}-{path.name}';shutil.copyfile(path,copy)
        pins.append(dict(original=str(path),snapshot=str(copy),sha256=sha(copy)))
    exe=Path('.build/release/blastbench').resolve();shutil.copyfile(exe,root/'runtime/blastbench');(root/'runtime/blastbench').chmod(0o755)
    for bundle in exe.parent.glob('*.bundle'):
        if 'test' not in bundle.name.lower():shutil.copytree(bundle,root/'runtime'/bundle.name,ignore=lambda directory,names:[n for n in names if blocked(n)])
    runtime={str(p.relative_to(root/'runtime')):sha(p) for p in (root/'runtime').rglob('*') if p.is_file()}
    linkage=subprocess.check_output(['otool','-L',str(exe)],text=True)
    assert all(line.strip().startswith(('/System/','/usr/lib/')) for line in linkage.splitlines()[1:])
    (root/'runtime-linkage.txt').write_text(linkage)
    context=dict(status='running',revision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
        dirty=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),frozenSources=pins,runtimeSHA256=runtime,
        python=sys.version,numpyVersion=np.__version__,commands=[],scope='Selected project/source/executable/resource freeze, not hermetic OS/driver/runtime provenance. nx128 CLI validation, not scientific fine-grid outcomes.')
    def save():
        temporary=root/'context.tmp';temporary.write_text(json.dumps(context,indent=2)+'\n');os.replace(temporary,root/'context.json')
    env=dict(os.environ)
    for key in list(env):
        if key.startswith('GPU_SLOT_') or key in ['BOMBCAD_KERNEL_MATH','BOMBCAD_KERNEL_CONTRACT','BOMBCAD_STATE_PADDING','BOMBCAD_STATE_PADDING_AT','BOMBCAD_KERNEL_PERTURB']:env.pop(key,None)
    def command(arguments,label):
        entry=dict(label=label,arguments=arguments,status='running');context['commands'].append(entry);save()
        with (root/'logs'/(label+'.log')).open('xb') as log:
            child=subprocess.Popen([str(Path.home()/'.local/bin/gpu-slot'),'--mem','2',str(root/'runtime/blastbench'),'acoustic-phase',*arguments],stdout=log,stderr=subprocess.STDOUT,env=env,start_new_session=True)
            def identity():
                return subprocess.run(['ps','-ww','-p',str(child.pid),'-o','lstart='],capture_output=True,text=True,env=dict(os.environ,LC_ALL='C',TZ='UTC')).stdout.strip()
            boot=lambda:subprocess.check_output(['sysctl','-n','kern.boottime'],text=True).strip()
            birth=identity();entry['process']=dict(pid=child.pid,pgid=child.pid,boot=boot(),birth=birth);save()
            try:entry['returncode']=child.wait(timeout=80*60)
            except subprocess.TimeoutExpired:
                entry['executionBudgetExceeded']=True;save()
                if not birth or identity()!=birth or boot()!=entry['process']['boot'] or child.poll() is not None:raise RuntimeError('budget ended; exact live owner not proven')
                os.killpg(child.pid,signal.SIGTERM)
                try:entry['returncode']=child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    if identity()!=birth or boot()!=entry['process']['boot']:raise RuntimeError('owner changed during termination')
                    os.killpg(child.pid,signal.SIGKILL);entry['returncode']=child.wait(timeout=30)
            groups=subprocess.check_output(['ps','-axo','pgid=,stat='],text=True)
            assert not any(int(p[0])==child.pid and not p[1].startswith('Z') for line in groups.splitlines() if len(p:=line.split())>=2),'owned descendant still live'
            entry['status']='terminal';save()
        return entry['returncode']
    save()
    try:
        for i,args in enumerate([['--trace-source-stencils'],['--trace-source-stencils','--trace-updates'],['--trace-source-stencils','--compensated','both']]):
            output=root/f'invalid-{i}';assert command([*args,'--out',str(output)],f'invalid-{i}')!=0 and not output.exists()
        output=root/'output';name='a100-n128-full'
        assert command(['--trace-source-stencils','--trace-updates','--compensated','both','--cfl','0.45','--rounding','default','--only-case',name,'--out',str(output)],'four-mode')==0
        load=lambda file:json.loads((output/file).read_text())
        runs=load('runs.json');assert len(runs['cases'])==1 and len(runs['cases'][0]['runs'])==4
        snapshots=[load(name+'-'+mode+'.json') for mode in ['plain','observed','updates','sources']]
        keys=['initialHashes','finalHashes','steps','time','records','initialConservedRhoMxEnergy','finalConservedRhoMxEnergy','initialResidualBits','finalResidualBits']
        parity={key:all(row[key]==snapshots[0][key] for row in snapshots[1:]) for key in keys};assert all(parity.values()) and all(row['stable'] for row in snapshots)
        assert len({sha(output/file) for file in [name+'-trace.json',name+'-update-pressure-trace.json',name+'-source-pressure-trace.json']})==1
        old=load(name+'-update-trace.json');new=load(name+'-source-stencil.json')
        for key in ['fields','valueEncoding','indices','steps','times','dt','executed','valueBits','initialStateBits','finalStateBits']:assert old[key]==new[key],key
        assert new['format']=='bombcad-compensated-source-stencil-1' and new['sourceObservation']=='host-physical-cells-before-blocking-part'
        assert new['sourcePhysicalIndices'][0]==[1,0,0,1,2] and new['sourceGhostVelocitySigns'][0]==[-1,-1,1,1,1]
        assert new['sourcePhysicalIndices'][-1]==[125,126,127,127,127]
        state=np.asarray(new['sourceConservedBits'],dtype=np.uint32);residual=np.asarray(new['sourceResidualBits'],dtype=np.uint32);words=np.asarray(new['valueBits'],dtype=np.uint32);active=np.asarray(new['executed'],dtype=bool)
        assert state.shape==(len(new['steps']),6,5,5) and residual.shape==(len(new['steps']),6,5,4)
        assert np.array_equal(state[:,:,2,:][active],words[:,:,:5][active])
        assert np.array_equal(residual[:,:,2,:][active],words[:,:,[24,25,28,29]][active])
        assert all(sha(pin['original'])==sha(pin['snapshot'])==pin['sha256'] for pin in pins)
        assert all(sha(root/'runtime'/name)==pin for name,pin in runtime.items())
        context.update(status='pass',observationParity=parity,pressureTraceBytesIdentical=True,allGPUWordsIdentical=True,sourceCentreWordsMatch=True,sourceShape=list(state.shape),residualShape=list(residual.shape),scientificMatrixExports=0)
    except BaseException as error:context.update(status='failed',error=repr(error));raise
    finally:save()
    print(json.dumps({k:v for k,v in context.items() if k not in ['frozenSources','runtimeSHA256','commands']},indent=2))


if __name__=='__main__':main()
