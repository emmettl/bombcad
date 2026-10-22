"""Verify capture fidelity and actual clock accounting before selector attribution."""
import importlib.util
import json
from pathlib import Path

import numpy as np

from run_metal import ROOT, HERE, BASE, sha, load


def verify_pin(path, expected):
    if sha(path) == expected:
        return
    transition = load(ROOT/'validation/controller-source-transition.json')
    rows = [r for r in transition['rows'] if r['originalPath'] == path and r['oldSHA256'] == expected]
    assert rows, path
    for row in rows:
        controller = load(ROOT/(row['stage']+'-controller.json'))
        assert controller['status']=='terminal' and controller['returncode']==0
        assert sha(row['frozenSource'])==expected and sha(path)==row['newSHA256'],path


def main():
    metal=load(ROOT/'metal-capture.json')
    baseline=load(ROOT/'baseline/receipt.json')
    cuda=load(ROOT/'capture/receipt.json')
    assert metal['status']=='complete-all-outcomes' and metal['allThreeCaptureGatesPass']
    assert baseline['allBaselineNumericParity'] and cuda['allCaptureNumericParity']
    assert len(metal['rows'])==len(cuda['rows'])==len(baseline['rows'])==3
    for r in metal['rows']:
        assert r['allOriginalNumericBytesEqual'] and all(r['metadataParity'].values())
    for mode in ['baseline','capture']:
        controller=load(ROOT/(mode+'-controller.json'))
        assert controller['status']=='terminal' and controller['returncode']==0
        for p,h in controller['pins'].items():verify_pin(p,h)
    for mapping in [metal['pins'],metal['consumed'],load(ROOT/'cuda-preparation.json')['pins']]:
        for p,h in mapping.items():verify_pin(p,h)
    spec=importlib.util.spec_from_file_location('frozen_wire',ROOT/'cuda-worker/job.py')
    wire=importlib.util.module_from_spec(spec);spec.loader.exec_module(wire)
    resource=ROOT/'runtime-metal/BombCAD_BlastCore.bundle/Contents/Resources/Shaders/Solver.metal'
    sources=dict(metal=resource.read_text(),cuda=(ROOT/'cuda-worker/solver.cu').read_text())
    consumed={}
    rows=[]
    schemas={}
    for backend,source in sources.items():
        Control=wire.scalar_layout(source,'StepControl');Uniform=wire.scalar_layout(source,'SolverUniforms')
        cfields={n:getattr(Control,n).offset//4 for n,_ in Control._fields_}
        ufields={n:getattr(Uniform,n).offset//4 for n,_ in Uniform._fields_}
        import ctypes
        cw,uw=ctypes.sizeof(Control)//4,ctypes.sizeof(Uniform)//4
        schemas[backend]=dict(controlFields=cfields,uniformFields=ufields,controlWords=cw,uniformWords=uw)
        for original in metal['rows']:
            name=original['id'];folder=ROOT/('metal' if backend=='metal' else 'capture')/name
            names=['clock-inputs.bin','clock-inputs.json','pressure-trace.npy','pressure-trace.json'] if backend=='metal' else ['clock-inputs.bin','clock-inputs.json','trace.npy','trace.json']
            for n in names:consumed[str(folder/n)]=sha(folder/n)
            info=load(folder/'clock-inputs.json')
            assert info['complete'] and info['dtype']=='<u4'
            assert info['controlWords']==cw and info['uniformWords']==uw
            width=14+2*cw+uw
            assert info['recordWords']==width
            a=np.fromfile(folder/'clock-inputs.bin',dtype='<u4').reshape(-1,width)
            assert len(a)==info['samples']==len(info['encodedSteps'])==len(info['batchBaseSteps'])
            offsets=dict(speedBefore=0,tilesBefore=2,controlBefore=6,uniforms=6+cw,
                controlAfter=6+cw+uw,speedAfter=6+2*cw+uw,tilesAfter=8+2*cw+uw,markers=width-2)
            assert info['offsets']==offsets
            assert np.all(a[:,-2:]==np.array([0x43505245,0x43504F53],dtype='<u4'))
            pre=a[:,6:6+cw];u=a[:,6+cw:6+cw+uw];post=a[:,6+cw+uw:6+2*cw+uw]
            dt=post[:,cfields['dt']].view('<f4')
            assert np.isfinite(dt).all() and (dt>=0).all()
            active=dt>0
            before=np.cumsum(active.astype(np.int64))-active
            assert np.array_equal(np.asarray(info['batchBaseSteps'])+pre[:,cfields['activeSteps']],before)
            assert np.array_equal(post[:,cfields['activeSteps']],pre[:,cfields['activeSteps']]+active)
            assert np.array_equal(post[:,cfields['stepIndex']],pre[:,cfields['stepIndex']]+1)
            def clock(control):return control[:,cfields['clockLow']].astype(np.uint64)|(control[:,cfields['clockHigh']].astype(np.uint64)<<32)
            pre_ticks=clock(pre);post_ticks=clock(post)
            increment=np.asarray([int(float(v)*2**40) for v in dt],dtype=np.uint64)
            assert np.array_equal(post_ticks,pre_ticks+increment)
            job_path=BASE/'cases'/name/'input/job.json'
            base_archive=load(HERE.parent/BASE.name/'pilot-archive.json')['files']
            assert sha(job_path)==base_archive[str(job_path.relative_to(BASE))]['sha256']
            consumed[str(job_path)]=sha(job_path)
            job=load(job_path)
            initial_match=None
            if backend=='metal':
                hashes=folder/'diagnostic-state-hashes.json'
                consumed[str(hashes)]=sha(hashes)
                initial=load(hashes)['initial']
                mapping=dict(state='state.bin',mask='mask.bin',species='species.bin',peak='peak.bin',
                    impulse='impulse.bin',firstPhaseColumns='columns.bin',firstPhaseRecords='records.bin',firstPhaseOpen='open.bin')
                initial_match={k:initial[k]==job['files'][v] for k,v in mapping.items()}
                assert all(initial_match.values())
            origin=int(np.floor(job['startTime']*2**40+.5)) if backend=='metal' else 0
            assert int(pre_ticks[0])==origin
            traces=np.load(folder/('pressure-trace.npy' if backend=='metal' else 'trace.npy'),allow_pickle=False)
            trace_info=load(folder/('pressure-trace.json' if backend=='metal' else 'trace.json'))
            selected=post[active] if backend=='metal' else post
            assert np.all(traces[:,:,6].view('<u4')==traces[:,0:1,6].view('<u4'))
            assert np.array_equal(selected[:,cfields['dt']],traces[1:,0,6].view('<u4'))
            assert np.array_equal(selected[:,cfields['batchTime']],traces[1:,0,7].view('<u4'))
            if backend=='metal':
                assert np.array_equal(post_ticks[active].astype(np.float64)/2**40,np.asarray(trace_info['times'][1:]))
            else:
                assert np.array_equal(job['startTime']+np.cumsum(dt.astype(np.float64)),np.asarray(trace_info['times'][1:]))
                assert sha(folder/'clock-inputs.bin')==sha(folder/'out-clock-inputs.partial.bin')
                assert np.all(a[:,2:6]==0) and np.all(a[:,offsets['tilesAfter']:offsets['tilesAfter']+4]==0)
            speed_after=a[:,offsets['speedAfter']:offsets['speedAfter']+2]
            assert np.all(u[:,ufields['forcedStep']]==0), 'No captured schedule or sleeping-body step'
            assert np.all(speed_after[active]==0)
            assert np.array_equal(speed_after[~active],a[~active,:2])
            tiled=u[:,ufields['tileNx']]!=0
            if backend=='metal':
                after_tile=a[:,offsets['tilesAfter']:offsets['tilesAfter']+4]
                assert np.array_equal(post[tiled,cfields['activeTiles']],a[tiled,2])
                assert np.array_equal(after_tile[tiled,0],np.zeros(np.count_nonzero(tiled),dtype='<u4'))
                assert np.array_equal(after_tile[tiled,1],a[tiled,2]) and np.all(after_tile[tiled,2:]==1)
                assert np.array_equal(after_tile[~tiled],a[~tiled,2:6])
            assert np.all(u[:,ufields['gaugeCount']]==0), 'Full-state/gauge context required before replaying nonzero gauges'
            rows.append(dict(backend=backend,id=name,encodedSamples=len(a),activeSteps=int(active.sum()),
                inactiveDispatches=int((~active).sum()),originTicks=origin,
                allMarkersAndControlCountersValid=True,allClockIncrementsExact=True,
                allNativeTraceDTAndBatchWordsExact=True,rawTimeAxisPreserved=True,
                tileContext='actual pre/post count and dispatch words' if backend=='metal' else 'absent full-grid context; zero placeholders',
                gaugeCountZero=True,clockSHA256=sha(folder/'clock-inputs.bin')))
            if initial_match is not None:rows[-1]['initialPhysicalBufferHashesMatchJob']=initial_match
    assert schemas['metal']==schemas['cuda'], 'Map fields explicitly if scalar layouts ever diverge'
    for p,h in consumed.items():assert sha(p)==h,p
    report=dict(status='all-six-capture-gates-and-accounting-verified',rows=rows,schemas=schemas,
        consumed=consumed,sourceSHA256=sha(__file__),allSixOwnBackendCaptureGatesPass=True,
        selectorReplay='pending native own-input word gates before cross attribution',
        defaultBulkGeneration='held; this proves observer fidelity, not Metal/CUDA target equivalence')
    (ROOT/'capture-audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['consumed','schemas']},indent=2))


if __name__=='__main__':main()
