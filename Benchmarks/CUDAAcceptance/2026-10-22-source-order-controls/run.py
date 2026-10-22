"""All-outcome saved-input written-order comparison, preceded by frozen controls."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import numpy as np

HERE=Path(__file__).resolve().parent
BASE=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-host-source-matrix')
ROOT=BASE.parent/'2026-10-22-source-order-controls'


def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def load(p):return json.loads(Path(p).read_text())
def save(p,value):
    temporary=Path(str(p)+'.tmp');temporary.write_text(json.dumps(value,indent=2)+'\n');os.replace(temporary,p)
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


def main():
    inventory=load(BASE.parent/'2026-10-22-host-source-publication/scientific-archive.json')['allRawFiles']
    for n in ['run.json','audit/results.json']:assert sha(BASE/n)==inventory[n]['sha256']
    prior=load(BASE/'audit/results.json');producer=load(BASE/'run.json')
    assert prior['allObservationAndPriorGates'] and prior['allFullTiledFinalParity'] and prior['allFullTiledSourceHistories']
    assert len(prior['rows'])==len(producer['plan']['jobs'])==432
    previous={r['label']:r for r in prior['rows']}
    ROOT.mkdir(exist_ok=False);(ROOT/'analysis').mkdir();(ROOT/'flux').mkdir()
    for name in ['written_order.py','check_models.py','run.py','plan.md']:shutil.copyfile(HERE/name,ROOT/'analysis'/name)
    pins={str(ROOT/'analysis'/n):sha(ROOT/'analysis'/n) for n in ['written_order.py','check_models.py','run.py','plan.md']}
    for name in ['source-audit.py','components.py','planar_euler.py']:
        p=BASE/'analysis'/name;assert sha(p)==inventory['analysis/'+name]['sha256'];pins[str(p)]=sha(p)
        shutil.copyfile(p,ROOT/'analysis'/('prior-'+name))
    for name in ['run.json','audit/results.json']:pins[str(BASE/name)]=inventory[name]['sha256']
    for p in (BASE/'sources').glob('*Solver.metal'):
        assert sha(p)==inventory[str(p.relative_to(BASE))]['sha256'];pins[str(p)]=sha(p);shutil.copyfile(p,ROOT/'analysis'/p.name)
    runtime=producer['environment']['runtimeBytePins']
    for pin in runtime:
        assert sha(pin['original'])==sha(pin['snapshot'])==pin['sha256'];pins[pin['original']]=pin['sha256']
    assert Path(sys.executable).resolve()==Path(runtime[0]['original']).resolve()
    state=dict(status='controls-running',controllerPID=os.getpid(),python=sys.version,numpy=np.__version__,pins=pins,
        predecessorArchiveSHA256=sha(BASE.parent/'2026-10-22-host-source-publication/scientific-archive.json'),
        rows=[],consumed={},limits='Fixed separate CPU models of written expressions, not GPU instruction attestation, physical dissipation or independently evolved PDE solutions. No producer/oracle rerun or default/admission change.')
    def verify():
        for p,h in pins.items():assert sha(p)==h,p
    def checkpoint():save(ROOT/'run.json',state)
    checkpoint()
    try:
        verify()
        env=dict(os.environ,OPENBLAS_NUM_THREADS='1',OMP_NUM_THREADS='1',MKL_NUM_THREADS='1',VECLIB_MAXIMUM_THREADS='1')
        with (ROOT/'controls.log').open('wb') as f:
            code=subprocess.call([sys.executable,'-B',str(ROOT/'analysis/check_models.py')],stdout=f,stderr=subprocess.STDOUT,env=env)
        state['controlsReturncode']=code;checkpoint();assert code==0,'Frozen mathematical controls failed; no scoring'
        sys.path.insert(0,str(BASE/'analysis'));validator=module('source_validator',BASE/'analysis/source-audit.py')
        model=module('written_order_frozen',ROOT/'analysis/written_order.py');state['status']='scoring';checkpoint()
        for job in producer['plan']['jobs']:
            label=job['label'];name=job['case'];row=dict(label=label,job=job,status='unavailable')
            try:
                assert previous[label]['status']=='audited' and previous[label]['eligibleAsCandidateObservation']
                folder=BASE/'cases'/label
                def read(suffix):
                    p=folder/(name+suffix);key=str(p.relative_to(BASE));assert sha(p)==inventory[key]['sha256']
                    state['consumed'][key]=inventory[key];return load(p)
                source=read('-source-stencil.json');updates=read('-update-trace.json');snapshot=read('-sources.json')
                d=validator.validate(source,updates,snapshot,job['nx']);yes=d['active'];cfg=d['configuration']
                history=hashlib.sha256(d['state'].tobytes()+d['residual'].tobytes()).hexdigest()
                assert history==previous[label]['source']['sourceHistorySHA256']
                physical=d['state'].view(np.float32)
                assert np.all(physical[...,2:4]==0),'nonzero tangential momentum unsupported'
                selected=physical[...,[0,1,4]][yes]
                signs=np.broadcast_to(d['signs'],physical.shape[:-1])[yes]
                raw=d['raw'].view(np.float32);lam=raw[...,20][yes]
                actual=np.stack([raw[...,[10,11,14]],raw[...,[15,16,19]]],axis=-2)[yes]
                arrays=dict(executedFlatIndices=np.flatnonzero(yes),actualFlux=actual);models={}
                for dtype in [np.float32,np.float64]:
                    key='written32' if dtype==np.float32 else 'written64'
                    r=model.operator(selected.astype(dtype),lam,cfg['gamma'],signs=signs,theta=cfg['limiterTheta'],density_floor=cfg['densityFloor'],pressure_floor=cfg['pressureFloor'])
                    flux=r['flux'];arrays[key]=flux;rounded=flux.astype(np.float32)
                    word=rounded.view(np.uint32)!=actual.view(np.uint32)
                    numeric=rounded!=actual;error=np.abs(flux.astype(np.float64)-actual.astype(np.float64))
                    difference=flux[:,1].astype(np.float64)-flux[:,0].astype(np.float64)
                    sameNative=actual[:,1]==actual[:,0]
                    models[key]=dict(roundedToFloat32WordDifferencesByComponent=np.count_nonzero(word,axis=(0,1)).tolist(),
                        roundedToFloat32NumericDifferencesByComponent=np.count_nonzero(numeric,axis=(0,1)).tolist(),
                        maximumAbsoluteFluxErrorByComponent=np.max(error,axis=(0,1)).tolist(),
                        wholeTraceRoundedWordCompatibility=not word.any(),reconstructionFallbacks=int(np.count_nonzero(r['fallback'])),
                        modelNonzeroFaceDifferenceWithEqualNativeFaces=np.count_nonzero((difference!=0)&sameNative,axis=0).tolist(),
                        fluxBytesSHA256=hashlib.sha256(flux.tobytes()).hexdigest())
                dest=ROOT/'flux'/(label+'.npz');np.savez_compressed(dest,**arrays)
                row.update(status='audited',executed=int(np.count_nonzero(yes)),skipped=int(np.count_nonzero(~yes)),models=models,
                    sourceHistorySHA256=history,derivedFileSHA256=sha(dest))
                del source,updates,snapshot,d,physical,raw,arrays
            except Exception as error:row.update(status='audit-failed',error=repr(error))
            state['rows'].append(row);checkpoint()
        lookup={r['label']:r for r in state['rows']};pairs=[]
        for row in state['rows']:
            if row['job']['tiled']:continue
            label=row['label'];other=lookup[label[:-4]+'tiled'];pair=dict(full=label,tiled=other['label'],eligible=False)
            if row['status']==other['status']=='audited':
                with np.load(ROOT/'flux'/(label+'.npz'),allow_pickle=False) as a,np.load(ROOT/'flux'/(other['label']+'.npz'),allow_pickle=False) as b:
                    _,ia,ib=np.intersect1d(a['executedFlatIndices'],b['executedFlatIndices'],assume_unique=True,return_indices=True)
                    pair.update(eligible=True,commonExecuted=len(ia),sameCompleteSourceHistory=row['sourceHistorySHA256']==other['sourceHistorySHA256'],
                        modelCommonExecutedFluxByteParity={key:np.array_equal(a[key][ia].view(np.uint8),b[key][ib].view(np.uint8)) for key in ['written32','written64']})
            pairs.append(pair)
        for n,pin in state['consumed'].items():assert sha(BASE/n)==pin['sha256']
        verify();state.update(status='complete-all-outcomes',fullTiledPairs=pairs,allRowsAudited=all(r['status']=='audited' for r in state['rows']))
        checkpoint();print(json.dumps({k:v for k,v in state.items() if k not in ['rows','consumed','pins','fullTiledPairs']},indent=2))
    except BaseException as error:state.update(status='failed',error=repr(error));checkpoint();raise


if __name__=='__main__':main()
