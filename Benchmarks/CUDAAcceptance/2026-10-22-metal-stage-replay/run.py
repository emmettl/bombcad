"""One component-output variant on every accepted saved stencil; no per-scalar promotion."""
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
PARENT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-metal-stencil-replay')
ROOT=PARENT.parent/'2026-10-22-metal-stage-replay'


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
    archive=load(REPO/'Benchmarks/CUDAAcceptance/2026-10-22-metal-stencil-replay/archive.json')
    assert sha(PARENT/'run.json')==archive['files']['run.json']['sha256']
    parent=load(PARENT/'run.json');assert parent['all432ByteCompatible'] and parent['allOwnedGroupsTerminal'] and len(parent['rows'])==432
    ROOT.mkdir(exist_ok=False)
    for n in ['analysis','runtime','controls','cases']:(ROOT/n).mkdir()
    pins={};consumed={}
    def inherit(relative):
        p=PARENT/relative;pin=archive['files'][relative];assert sha(p)==pin['sha256']
        consumed[relative]=pin;return p
    inherit('run.json');inherit('control-results.json');inherit('control-definitions.json')
    for n in ['run.py','generate.py','replay.swift','plan.md']:
        p=ROOT/'analysis'/n;shutil.copyfile(HERE/n,p);pins[str(p)]=sha(p)
    for n in ['0528-Solver.metal','replay.metal']:
        p=inherit('analysis/'+n);shutil.copyfile(p,ROOT/'analysis'/n)
    generator=module('stage_builder',ROOT/'analysis/generate.py')
    text,fields=generator.build((ROOT/'analysis/0528-Solver.metal').read_text(),(ROOT/'analysis/replay.metal').read_text())
    assert len(fields)==91
    (ROOT/'analysis/stage-replay.metal').write_text(text)
    save(ROOT/'fields.json',dict(format='bombcad-replay-stages-1',fields=fields,words=91,scope='Locals in separate replay, not observed production intermediates'))
    pins[str(ROOT/'analysis/stage-replay.metal')]=sha(ROOT/'analysis/stage-replay.metal');pins[str(ROOT/'fields.json')]=sha(ROOT/'fields.json')
    for p,h in parent['pins'].items():
        if 'codex-primary-runtime/dependencies/python' in p:
            assert sha(p)==h;pins[p]=h
    (ROOT/'analysis/queue-imports').mkdir()
    for n in ['field-queue.py','compare_dataset.py','generate.py','job.py','remote.py']:
        p=inherit('analysis/queue-imports/'+n);dest=ROOT/'analysis/queue-imports'/n
        shutil.copyfile(p,dest);pins[str(dest)]=sha(dest)
    sys.path.insert(0,str(ROOT/'analysis/queue-imports'));q=module('process_helpers',ROOT/'analysis/queue-imports/field-queue.py')
    state=dict(status='building',controllerPID=os.getpid(),boot=q.boot_id(),python=sys.version,numpy=np.__version__,
        pins=pins,consumed=consumed,commands=[],rows=[],words=91,parentArchiveSHA256=sha(REPO/'Benchmarks/CUDAAcceptance/2026-10-22-metal-stencil-replay/archive.json'))
    def checkpoint():save(ROOT/'run.json',state)
    def verify():
        for p,h in pins.items():assert sha(p)==h,p
        for n,p in consumed.items():assert sha(PARENT/n)==p['sha256'],n
    def command(args,label,gpu=False):
        verify()
        with (ROOT/(label+'.log')).open('wb') as f:
            p=subprocess.Popen(args,cwd=REPO,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            entry=dict(label=label,pid=p.pid,pgid=p.pid,boot=q.boot_id(),identity=q.process_snapshot(p.pid),command=args)
            state['liveProcess']=entry;checkpoint()
            try:code=p.wait(timeout=4800 if gpu else 600)
            except subprocess.TimeoutExpired:
                identity=q.process_snapshot(p.pid)
                assert q.boot_id()==entry['boot'] and identity and identity['birth']==entry['identity']['birth'] and identity['command']==entry['identity']['command']
                os.killpg(p.pid,signal.SIGTERM)
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    identity=q.process_snapshot(p.pid);assert identity and identity['birth']==entry['identity']['birth'] and identity['command']==entry['identity']['command']
                    os.killpg(p.pid,signal.SIGKILL);p.wait()
                code=p.returncode;entry['timedOut']=True
            entry['returncode']=code;state['commands'].append(entry);state.pop('liveProcess');checkpoint()
        assert not q.group_alive(p.pid);verify();assert code==0,(label,code)
    def items(entries,kind):
        result=[]
        for old in entries:
            folder=ROOT/kind/old['label'];folder.mkdir()
            source=Path(old['folder']);relative=str(source.relative_to(PARENT))
            for name in ['state.bin','signs.bin','lambda.bin','uniforms.bin','expected.bin','replayed.bin']:
                inherit(relative+'/'+name)
            item={**old,'folder':str(folder),'inputFolder':str(source)}
            if kind=='cases':inherit(relative+'/executed-indices.npy')
            result.append(item)
        return result
    def gpu(entries,label):
        manifest=ROOT/(label+'-manifest.json');save(manifest,dict(source=str(ROOT/'analysis/stage-replay.metal'),cases=entries))
        command([str(Path.home()/'.local/bin/gpu-slot'),'--mem','1',str(ROOT/'runtime/replay'),str(manifest),str(ROOT/(label+'-receipt.json'))],label,True)
        r=load(ROOT/(label+'-receipt.json'));assert r['status']=='complete-all-outcomes' and r['recordWords']==91
        assert r['binarySHA256']==pins[str(ROOT/'runtime/replay')] and r['manifestSHA256']==sha(manifest)
        expected={p:hashlib.sha256((('#pragma METAL fp contract(off)\n' if p=='unfused' else '')+text).encode()).hexdigest() for p in ['default','unfused']}
        assert r['sourceSHA256']==expected and [x['label'] for x in r['rows']]==[x['label'] for x in entries]
        for item,row in zip(entries,r['rows']):
            if row['status']!='complete':continue
            relative=str(Path(item['inputFolder']).relative_to(PARENT))
            assert row['inputSHA256']=={n:consumed[relative+'/'+n]['sha256'] for n in ['state.bin','signs.bin','lambda.bin','uniforms.bin']}
            assert row['outputSHA256']==sha(Path(item['folder'])/'replayed.bin')
        return r
    checkpoint()
    try:
        compiler=Path(subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip());pins[str(compiler)]=sha(compiler)
        xcrun=Path(shutil.which('xcrun'));pins[str(xcrun)]=sha(xcrun)
        state['compilerVersion']=subprocess.check_output([str(compiler),'--version'],text=True)
        state['sdk']=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip();state['deploymentTarget']='arm64-apple-macosx14.0'
        checkpoint();command([str(xcrun),'--sdk','macosx','swiftc','-O','-warnings-as-errors','-target',state['deploymentTarget'],'-sdk',state['sdk'],
            '-module-cache-path',str(ROOT.with_name(ROOT.name+'-build-cache')),str(ROOT/'analysis/replay.swift'),'-o',str(ROOT/'runtime/replay')],'build')
        pins[str(ROOT/'runtime/replay')]=sha(ROOT/'runtime/replay');checkpoint();gpu([],'compile-preflight')
        control_items=items(load(inherit('controls-manifest.json'))['cases'],'controls')
        state['status']='controls';checkpoint();r=gpu(control_items,'controls');definitions=load(PARENT/'control-definitions.json');checks=[]
        for item,row in zip(control_items,r['rows']):
            assert row['status']=='complete',row
            a=np.fromfile(Path(item['folder'])/'replayed.bin',dtype='<f4').reshape(-1,91);assert a.shape==(1,91) and np.isfinite(a).all()
            prefix=a[0,:10].reshape(2,5);definition=definitions[item['label']];bound=np.array(definition['bound']);analytic=np.array(definition['analytic'])
            if definition['kind']=='wall':ok=abs(prefix[0,0])<=bound[0] and abs(prefix[0,4])<=bound[4] and prefix[0,1]>0
            else:ok=np.array_equal(prefix[0],prefix[1]) and bool(np.all(np.abs(prefix-analytic)<=bound))
            checks.append(dict(label=item['label'],passed=bool(ok),prefix=prefix.tolist(),all91FieldsFinite=True,definition=definition))
        save(ROOT/'control-results.json',checks);assert all(c['passed'] for c in checks),'Analytic control failed; no corpus scoring'
        state['status']='preparing';checkpoint()
        entries=items([r['input'] for r in parent['rows']],'cases')
        assert len(entries)==432 and all(r['status']=='audited' and r['wholeTraceByteCompatible'] for r in parent['rows'])
        state['status']='replaying';checkpoint();r=gpu(entries,'scientific')
        for old,item,result in zip(parent['rows'],entries,r['rows']):
            row=dict(label=item['label'],job=old['job'],status='audit-failed',executed=old['executed'],skipped=old['skipped'],inputFolder=item['inputFolder'])
            try:
                assert result['status']=='complete',result
                folder=Path(item['folder']);out=np.fromfile(folder/'replayed.bin',dtype='<f4').reshape(-1,91)
                assert out.shape==(item['count'],91);finite=bool(np.isfinite(out).all());assert finite,'Nonfinite stage output'
                native=np.fromfile(Path(item['inputFolder'])/'expected.bin',dtype='<f4').reshape(-1,2,5)
                previous=np.fromfile(Path(item['inputFolder'])/'replayed.bin',dtype='<f4').reshape(native.shape)
                prefix=out[:,:10].copy().reshape(native.shape);word=prefix.view(np.uint32)!=native.view(np.uint32)
                row.update(status='audited',all91FieldsFinite=finite,wholeTraceFluxByteCompatible=not word.any(),
                    previousFluxReplayByteCompatible=np.array_equal(prefix.view(np.uint32),previous.view(np.uint32)),
                    wordDifferencesByComponent=np.count_nonzero(word,axis=(0,1)).tolist(),numericDifferencesByComponent=np.count_nonzero(prefix!=native,axis=(0,1)).tolist(),
                    maximumAbsoluteFluxErrorByComponent=np.max(np.abs(prefix.astype(np.float64)-native.astype(np.float64)),axis=(0,1)).tolist(),outputSHA256=result['outputSHA256'])
            except Exception as error:row['error']=repr(error)
            state['rows'].append(row);checkpoint()
        lookup={r['label']:r for r in state['rows']};pairs=[]
        for row in state['rows']:
            if row['job']['tiled']:continue
            other=lookup[row['label'][:-4]+'tiled'];pair=dict(full=row['label'],tiled=other['label'],eligible=False)
            if row['status']==other['status']=='audited':
                _,ia,ib=np.intersect1d(np.load(Path(row['inputFolder'])/'executed-indices.npy',allow_pickle=False),np.load(Path(other['inputFolder'])/'executed-indices.npy',allow_pickle=False),assume_unique=True,return_indices=True)
                a=np.fromfile(ROOT/'cases'/row['label']/'replayed.bin',dtype='<u4').reshape(-1,91)[ia]
                b=np.fromfile(ROOT/'cases'/other['label']/'replayed.bin',dtype='<u4').reshape(-1,91)[ib]
                pair.update(eligible=True,commonExecuted=len(ia),all91CommonExecutedWordParity=np.array_equal(a,b))
            pairs.append(pair)
        verify();state.update(status='complete-all-outcomes',allOwnedGroupsTerminal=True,fullTiledPairs=pairs,
            all432FluxByteCompatible=len(state['rows'])==432 and all(r.get('wholeTraceFluxByteCompatible',False) and r.get('previousFluxReplayByteCompatible',False) for r in state['rows']),
            allCommonFullTiledPayloadParity=all(p['eligible'] and p['all91CommonExecutedWordParity'] for p in pairs))
        state['eligibleForSubsequentStageComparison']=state['all432FluxByteCompatible'] and state['allCommonFullTiledPayloadParity'] and all(r.get('all91FieldsFinite',False) for r in state['rows'])
        checkpoint();print(json.dumps({k:v for k,v in state.items() if k not in ['pins','consumed','rows','fullTiledPairs']},indent=2))
    except BaseException as error:state.update(status='failed',error=repr(error));checkpoint();raise


if __name__=='__main__':main()
