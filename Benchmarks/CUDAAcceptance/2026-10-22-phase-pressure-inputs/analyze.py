"""Seeded native replay gates, then all fixed Double pressure counterfactuals."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import numpy as np
from pressure_model import f32,overpressure

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-phase-pressure-inputs')
BASE=ROOT.parent/'2026-10-22-fixed-terrain-reference'


def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def load(p):return json.loads(Path(p).read_text())
def word(x):return struct.unpack('<I',struct.pack('<f',x))[0]
def value(x):return struct.unpack('<f',struct.pack('<I',x))[0]


def replay(pressures,dt,seed,expected=None):
    x,y,z,w,going=map(f32,seed);differences=0;transitions=[];last=going
    for i,(p,d) in enumerate(zip(pressures,dt)):
        p=f32(p);d=f32(max(float(d),0.))
        y=f32(y+f32(max(p,0.)*d));x=max(x,p)
        if going:
            if p<0:going=0.
            else:z=y;w=max(w,p)
        if p>0 and w<.5*x:z=y;w=p;going=1.
        current=[x,y,z,w,going]
        if expected is not None:differences+=sum(word(a)!=word(b) for a,b in zip(current,expected[i]))
        if going!=last:transitions.append(dict(sample=i,open=going,pressure=p,firstPhaseImpulse=z));last=going
    return dict(final=[x,y,z,w,going],recordWordDifferences=differences,transitions=transitions)


def main():
    run=load(ROOT/'run.json');assert run['status']=='complete-all-outcomes' and run['allThreeCaptured']
    gated=[];consumed={}
    def read_array(p):
        consumed[str(p)]=sha(p);return np.load(p,allow_pickle=False)
    for case in run['rows']:
        name=case['id'];folder=ROOT/'cases'/name;proof=load(folder/'parity-and-endpoints.json');meta=load(folder/'trace.json')
        trace=read_array(folder/'trace.npy');inputs=read_array(folder/'pressure-inputs.npy')
        assert trace.dtype==inputs.dtype==np.dtype('<f4') and trace.shape==(len(meta['times']),len(case['columns']),8)
        assert inputs.shape==(*trace.shape[:2],16) and np.isfinite(trace).all() and np.isfinite(inputs).all()
        assert meta['columns']==case['columns'] and len(proof['baseline'])==9
        if name=='beirut-p0-1':
            prior=ROOT.parent/'2026-10-22-corrected-beirut-trace/cuda/trace.npy'
            consumed[str(prior)]=sha(prior);assert sha(prior)==sha(folder/'trace.npy'),'Beirut native trace changed'
        reference=read_array(BASE/'cases'/name/'metal/targets.npy')
        native_path=BASE/'recovery/current'/name/'out/firstPhaseImpulse.npy'
        assert sha(native_path)==proof['baseline']['firstPhaseImpulse.npy']['sha256'];native=read_array(native_path)
        columns=[]
        for q,endpoint in enumerate(proof['endpoints']):
            assert endpoint['column']==case['columns'][q]
            words=inputs[:,q].view(np.uint32);col=np.array(endpoint['columnWords'],dtype=np.uint32)
            assert np.all(words[:,:4]==col) and inputs[0,q,3]>0
            z=inputs[0,q,2];weights=np.array([f32(1.-float(z)),z],dtype=np.float32).view(np.uint32)
            assert np.all(words[:,4:6]==weights)
            assert np.array_equal(words[0,6:].reshape(2,5),np.array(endpoint['initialCellWords'],dtype=np.uint32))
            assert np.array_equal(words[-1,6:].reshape(2,5),np.array(endpoint['finalCellWords'],dtype=np.uint32))
            seed=[value(x) for x in endpoint['initialRecordWords']]+[value(endpoint['initialOpenWord'])]
            baseline=replay(trace[:,q,0],trace[:,q,6],seed,trace[:,q,1:6]);assert baseline['recordWordDifferences']==0,'Seeded native recorder replay differs'
            n=endpoint['column'];assert word(trace[-1,q,3])==word(native.flat[n])
            columns.append(dict(column=n,seed=seed,nativeReplay=baseline,metalFirstPhase=float(reference[2].flat[n]),cudaFirstPhase=float(native.flat[n])))
        gated.append((case,proof,meta,trace,inputs,columns))
    # No conditional model is evaluated until every case's input/recorder gate passed.
    rows=[]
    for case,proof,meta,trace,inputs,columns in gated:
        folder=ROOT/'cases'/case['id'];arrays={};models=[]
        for method in ['source64','root64']:
            for weights in ['native','column64']:
                key=method+'-'+weights;p=np.empty(inputs.shape[:2],dtype=np.float64)
                for i in range(len(p)):
                    for q in range(p.shape[1]):p[i,q]=overpressure(inputs[i,q],proof['uniforms'],method,weights)
                assert np.isfinite(p).all();arrays[key]=p;results=[]
                for q,c in enumerate(columns):
                    conditional=replay(p[:,q],trace[:,q,6],c['seed'])
                    native_closings=[t['sample'] for t in c['nativeReplay']['transitions'] if t['open']==0]
                    results.append(dict(column=c['column'],conditionalRecorder=conditional,
                        pressureAtEveryNativeClosing=[dict(sample=i,time=meta['times'][i],nativePressure=float(trace[i,q,0]),doublePressure=float(p[i,q]),roundedDoublePressure=f32(float(p[i,q]))) for i in native_closings],
                        finalDifferenceFromMetal=abs(conditional['final'][2]-c['metalFirstPhase']),unchangedAllowance=.05+.002*abs(c['metalFirstPhase']),
                        maximumPressureDifference=float(np.max(np.abs(p[:,q]-trace[:,q,0].astype(np.float64))))))
                models.append(dict(model=key,columns=results))
        np.savez_compressed(folder/'conditional-pressures.npz',**arrays)
        rows.append(dict(id=case['id'],nativeColumns=columns,models=models,inputAndSeededNativeReplayGatesPass=True))
    for p,h in consumed.items():assert sha(p)==h
    result=dict(status='complete-all-outcomes',allThreeInputAndNativeReplayGatesPass=True,rows=rows,consumed=consumed,
        analysisSHA256=sha(__file__),modelSHA256=sha(Path(__file__).with_name('pressure_model.py')),
        limits='Double evaluation uses represented CUDA inputs and promoted Float32 source parameters; it is conditional, not native instruction emulation, continuum truth or a Metal-state observation. Initial native recorder seeds and every sample including initial were replayed. Counterfactual labels change no actual output, rule, mask, tolerance or admission.')
    with (ROOT/'analysis-results.json').open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['rows','consumed']},indent=2))


if __name__=='__main__':main()
