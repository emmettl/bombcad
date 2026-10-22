"""Frozen standalone Metal replay controls and all-outcome archived-stencil comparison."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import numpy as np

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
BASE=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-host-source-matrix')
ROOT=BASE.parent/'2026-10-22-metal-stencil-replay'


def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def load(p):return json.loads(Path(p).read_text())
def save(p,v):
    tmp=Path(str(p)+'.tmp');tmp.write_text(json.dumps(v,indent=2)+'\n');os.replace(tmp,p)
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


def main():
    assert sys.byteorder=='little'
    inventory=load(BASE.parent/'2026-10-22-host-source-publication/scientific-archive.json')['allRawFiles']
    producer=load(BASE/'run.json');prior=load(BASE/'audit/results.json')
    assert len(producer['plan']['jobs'])==432 and prior['allObservationAndPriorGates'] and prior['allFullTiledFinalParity'] and prior['allFullTiledSourceHistories']
    priorRows={r['label']:r for r in prior['rows']}
    assert len(priorRows)==432
    ROOT.mkdir(exist_ok=False)
    for name in ['analysis','runtime','controls','cases']:(ROOT/name).mkdir()
    for preflight in sorted(ROOT.parent.glob(ROOT.name+'-preflight-*')):
        shutil.copytree(preflight,ROOT/preflight.name.removeprefix(ROOT.name+'-'))
    pins={};consumed={}
    def dependency(path):
        key=str(path.relative_to(BASE));assert sha(path)==inventory[key]['sha256'];pins[str(path)]=inventory[key]['sha256'];return path
    for name in ['plan.md','run.py','replay.swift','replay.metal']:
        dest=ROOT/'analysis'/name;shutil.copyfile(HERE/name,dest);pins[str(dest)]=sha(dest)
    for name in ['run.json','audit/results.json','analysis/source-audit.py','analysis/components.py']:
        dependency(BASE/name)
    parser=REPO/'Scripts/cuda/job.py';shutil.copyfile(parser,ROOT/'analysis/portable-job.py')
    pins[str(parser)]=pins[str(ROOT/'analysis/portable-job.py')]=sha(parser)
    snapshots={Path(p['original']).name:Path(p['path']) for p in producer['frozenSources']}
    for name in ['Solver.metal','StructureTypes+GPU.swift','StructureTypes.swift','CompensatedSweep.swift','SweepUpdateDiagnostics.swift']:
        p=dependency(snapshots[name]);shutil.copyfile(p,ROOT/'analysis'/p.name)
    original=(snapshots['Solver.metal']).read_text();text=original+'\n'+(ROOT/'analysis/replay.metal').read_text()
    (ROOT/'analysis/solver-replay.metal').write_text(text);pins[str(ROOT/'analysis/solver-replay.metal')]=sha(ROOT/'analysis/solver-replay.metal')
    for pin in producer['environment']['runtimeBytePins']:
        assert sha(pin['original'])==pin['sha256'];pins[pin['original']]=pin['sha256']
    assert Path(sys.executable).resolve()==Path(producer['environment']['runtimeBytePins'][0]['original']).resolve()
    sys.path.insert(0,str(BASE/'analysis'));validator=module('source_validator',BASE/'analysis/source-audit.py')
    portable=module('portable_layout',ROOT/'analysis/portable-job.py');U=portable.scalar_layout(original,'SolverUniforms')
    sys.path.insert(0,str(REPO/'Scripts/cuda'))
    (ROOT/'analysis/queue-imports').mkdir()
    for name in ['field-queue.py','compare_dataset.py','generate.py','job.py','remote.py']:
        p=REPO/'Scripts/cuda'/name;dest=ROOT/'analysis/queue-imports'/name
        shutil.copyfile(p,dest);pins[str(p)]=pins[str(dest)]=sha(p)
    q=module('queue',REPO/'Scripts/cuda/field-queue.py')
    state=dict(status='building',controllerPID=os.getpid(),boot=q.boot_id(),python=sys.version,numpy=np.__version__,pins=pins,consumed=consumed,commands=[],rows=[])
    def checkpoint():save(ROOT/'run.json',state)
    def verify():
        for p,h in pins.items():assert sha(p)==h,p
    def command(args,label,gpu=False):
        verify()
        with (ROOT/(label+'.log')).open('wb') as log:
            p=subprocess.Popen(args,cwd=REPO,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            entry=dict(label=label,pid=p.pid,pgid=p.pid,identity=q.process_snapshot(p.pid),boot=q.boot_id(),command=args)
            state['liveProcess']=entry;checkpoint()
            try:code=p.wait(timeout=4800 if gpu else 600)
            except subprocess.TimeoutExpired:
                identity=q.process_snapshot(p.pid)
                assert q.boot_id()==entry['boot'] and identity and identity['birth']==entry['identity']['birth'] and identity['command']==entry['identity']['command'],'Refuse signal after identity change'
                os.killpg(p.pid,signal.SIGTERM)
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    identity=q.process_snapshot(p.pid)
                    assert identity and identity['birth']==entry['identity']['birth'] and identity['command']==entry['identity']['command']
                    os.killpg(p.pid,signal.SIGKILL);p.wait()
                entry['timedOut']=True;code=p.returncode
            entry['returncode']=code;state['commands'].append(entry);state.pop('liveProcess');checkpoint()
        assert not q.group_alive(p.pid),'Owned descendant remains live'
        verify();assert code==0,(label,code)
    def uniform(cfg,nx):
        u=U();u.nx=nx;u.ny=u.nz=1;u.axis=0;u.airModel=0;u.riemannSolver=0;u.ambientPressure=101325
        for k in ['gamma','dx','densityFloor','pressureFloor','limiterTheta']:setattr(u,k,cfg[k])
        return bytes(u)
    def prepare(folder,label,policy,cells,signs,lam,cfg,nx,expected):
        folder.mkdir();n=len(cells)
        for name,data in [('state.bin',cells.astype('<u4',copy=False).tobytes()),('signs.bin',signs.astype('<i4').tobytes()),
                          ('lambda.bin',lam.astype('<f4').tobytes()),('uniforms.bin',uniform(cfg,nx)),('expected.bin',expected.astype('<f4').tobytes())]:
            (folder/name).write_bytes(data)
        entry=dict(label=label,folder=str(folder),policy=policy,count=n,uniformBytes=ctypes.sizeof(U))
        entry['inputSHA256']={p.name:sha(p) for p in folder.iterdir() if p.is_file()}
        return entry
    def gpu(items,label):
        manifest=ROOT/(label+'-manifest.json');save(manifest,dict(source=str(ROOT/'analysis/solver-replay.metal'),cases=items))
        command([str(Path.home()/'.local/bin/gpu-slot'),'--mem','1',str(ROOT/'runtime/replay'),str(manifest),str(ROOT/(label+'-receipt.json'))],label,True)
        receipt=load(ROOT/(label+'-receipt.json'));assert receipt['status']=='complete-all-outcomes'
        assert receipt['binarySHA256']==pins[str(ROOT/'runtime/replay')]
        assert receipt['manifestSHA256']==sha(manifest)
        expected={p:hashlib.sha256((('#pragma METAL fp contract(off)\n' if p=='unfused' else '')+text).encode()).hexdigest() for p in ['default','unfused']}
        assert receipt['sourceSHA256']==expected
        assert [x['label'] for x in receipt['rows']]==[x['label'] for x in items]
        return receipt
    checkpoint()
    try:
        compiler=Path(subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip())
        pins[str(compiler)]=sha(compiler);state['compilerResolvedPath']=str(compiler.resolve())
        state['compilerVersion']=subprocess.check_output([str(compiler),'--version'],text=True);checkpoint()
        sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
        state['sdk']=sdk;state['deploymentTarget']='arm64-apple-macosx14.0'
        xcrun=Path(shutil.which('xcrun'));pins[str(xcrun)]=sha(xcrun);checkpoint()
        command([str(xcrun),'--sdk','macosx','swiftc','-O','-warnings-as-errors','-target',state['deploymentTarget'],'-sdk',sdk,
                 '-module-cache-path',str(ROOT.with_name(ROOT.name+'-build-cache')),
                 str(ROOT/'analysis/replay.swift'),'-o',str(ROOT/'runtime/replay')],'build')
        pins[str(ROOT/'runtime/replay')]=sha(ROOT/'runtime/replay');checkpoint()
        # Build both Metal variants without issuing a numerical dispatch.
        gpu([],'compile-preflight')
        cfg=dict(gamma=float(np.float32(1.4)),dx=.25,densityFloor=float(np.float32(1e-6)),pressureFloor=float(np.float32(1e-3)),limiterTheta=1.5)
        controls=[];definitions={}
        for policy in ['default','unfused']:
            for kind,v in [('stationary',0.),('moving',.125),('wall',.125)]:
                label=policy+'-'+kind;rho=1.25;p=101325.;g=cfg['gamma']
                cell=np.array([rho,rho*v,0,0,p/(g-1)+.5*rho*v*v],dtype=np.float32)
                cells=np.tile(cell,(1,5,1)).view(np.uint32);signs=np.array([[-1,-1,1,1,1] if kind=='wall' else [1]*5])
                rv=float(cell[1])/float(cell[0]);rp=(g-1)*(float(cell[4])-.5*float(cell[0])*rv*rv);c=np.sqrt(g*rp/rho);speed=abs(rv)+c
                analytic=np.array([rho*rv,rho*rv*rv+rp,0,0,(float(cell[4])+rp)*rv],dtype=np.float64)
                bound=32*np.finfo(np.float32).eps*np.array([rho*speed,rp+rho*speed*speed,1,1,(float(cell[4])+rp)*speed])
                definitions[label]=dict(kind=kind,analytic=analytic.tolist(),bound=bound.tolist())
                controls.append(prepare(ROOT/'controls'/label,label,policy,cells,signs,np.array([.0001],dtype=np.float32),cfg,128,np.tile(analytic,(1,2)).astype(np.float32)))
        save(ROOT/'control-definitions.json',definitions);state['status']='controls';checkpoint()
        receipt=gpu(controls,'controls');checks=[]
        for item,row in zip(controls,receipt['rows']):
            assert row['status']=='complete',row
            for n,h in item['inputSHA256'].items():assert sha(Path(item['folder'])/n)==h
            assert row['inputSHA256']=={k:v for k,v in item['inputSHA256'].items() if k!='expected.bin'}
            assert row['outputSHA256']==sha(Path(item['folder'])/'replayed.bin')
            a=np.fromfile(Path(item['folder'])/'replayed.bin',dtype='<f4').reshape(2,5);definition=definitions[item['label']]
            assert np.isfinite(a).all();bound=np.array(definition['bound']);analytic=np.array(definition['analytic'])
            if definition['kind']=='wall':ok=abs(a[0,0])<=bound[0] and abs(a[0,4])<=bound[4] and a[0,1]>0
            else:ok=np.array_equal(a[0],a[1]) and bool(np.all(np.abs(a-analytic)<=bound))
            checks.append(dict(label=item['label'],passed=bool(ok),actual=a.tolist(),definition=definition))
        save(ROOT/'control-results.json',checks);assert all(c['passed'] for c in checks),'Analytic control failed; no scientific scoring'
        state['status']='preparing';checkpoint();items=[]
        for job in producer['plan']['jobs']:
            label=job['label'];name=job['case'];row=dict(label=label,job=job,status='preparation-failed')
            try:
                assert priorRows[label]['status']=='audited' and priorRows[label]['eligibleAsCandidateObservation']
                values=[]
                for suffix in ['-source-stencil.json','-update-trace.json','-sources.json']:
                    p=BASE/'cases'/label/(name+suffix);dependency(p);consumed[str(p.relative_to(BASE))]=inventory[str(p.relative_to(BASE))];values.append(load(p))
                d=validator.validate(*values,job['nx']);yes=d['active'];raw=d['raw'].view(np.float32)
                assert hashlib.sha256(d['state'].tobytes()+d['residual'].tobytes()).hexdigest()==priorRows[label]['source']['sourceHistorySHA256']
                assert np.all(d['state'].view(np.float32)[...,2:4]==0) and np.all(raw[...,22][yes]==0)
                entry=prepare(ROOT/'cases'/label,label,job['policy'],d['state'][yes],np.broadcast_to(d['signs'],d['state'].shape[:-1])[yes],raw[...,20][yes],d['configuration'],job['nx'],raw[...,10:20][yes])
                np.save(ROOT/'cases'/label/'executed-indices.npy',np.flatnonzero(yes))
                row.update(status='prepared',executed=int(yes.sum()),skipped=int((~yes).sum()),input=entry);items.append(entry)
            except Exception as error:row['error']=repr(error)
            state['rows'].append(row);checkpoint()
        state['status']='replaying';checkpoint();result=gpu(items,'scientific');lookup={r['label']:r for r in result['rows']}
        for row in state['rows']:
            if row['status']!='prepared':continue
            try:
                returned=lookup[row['label']];assert returned['status']=='complete',returned
                folder=Path(row['input']['folder'])
                for n,h in row['input']['inputSHA256'].items():assert sha(folder/n)==h
                assert returned['inputSHA256']=={k:v for k,v in row['input']['inputSHA256'].items() if k!='expected.bin'}
                assert returned['outputSHA256']==sha(folder/'replayed.bin')
                a=np.fromfile(folder/'expected.bin',dtype='<f4').reshape(-1,2,5);b=np.fromfile(folder/'replayed.bin',dtype='<f4').reshape(a.shape)
                assert np.isfinite(a).all() and np.isfinite(b).all();word=a.view(np.uint32)!=b.view(np.uint32)
                row.update(status='audited',wordDifferencesByComponent=np.count_nonzero(word,axis=(0,1)).tolist(),
                    numericDifferencesByComponent=np.count_nonzero(a!=b,axis=(0,1)).tolist(),maximumAbsoluteErrorByComponent=np.max(np.abs(a.astype(np.float64)-b.astype(np.float64)),axis=(0,1)).tolist(),
                    wholeTraceByteCompatible=not word.any(),outputSHA256=returned['outputSHA256'])
            except Exception as error:row.update(status='audit-failed',error=repr(error))
        pairs=[];rows={r['label']:r for r in state['rows']}
        for row in state['rows']:
            if row['job']['tiled']:continue
            other=rows[row['label'][:-4]+'tiled'];pair=dict(full=row['label'],tiled=other['label'],eligible=False)
            if row['status']==other['status']=='audited':
                a=Path(row['input']['folder']);b=Path(other['input']['folder'])
                _,ia,ib=np.intersect1d(np.load(a/'executed-indices.npy',allow_pickle=False),np.load(b/'executed-indices.npy',allow_pickle=False),assume_unique=True,return_indices=True)
                x=np.fromfile(a/'replayed.bin',dtype='<u4').reshape(-1,10)[ia]
                y=np.fromfile(b/'replayed.bin',dtype='<u4').reshape(-1,10)[ib]
                pair.update(eligible=True,commonExecuted=len(ia),commonExecutedReplayByteParity=np.array_equal(x,y))
            pairs.append(pair)
        verify();state.update(status='complete-all-outcomes',fullTiledPairs=pairs,allRowsAudited=all(r['status']=='audited' for r in state['rows']),
            all432ByteCompatible=len(state['rows'])==432 and all(r.get('wholeTraceByteCompatible',False) for r in state['rows']),allOwnedGroupsTerminal=True)
        checkpoint();print(json.dumps({k:v for k,v in state.items() if k not in ['pins','consumed','rows','fullTiledPairs']},indent=2))
    except BaseException as error:state.update(status='failed',error=repr(error));checkpoint();raise


if __name__=='__main__':main()
