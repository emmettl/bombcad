#!/usr/bin/env python3
"""Run an exported uniform, fixed-geometry BombCAD job on CUDA; write dataset targets."""
import argparse
import ctypes as C
import hashlib
import importlib.util
import json
from pathlib import Path
import time
from job import scalar_layout, validate


TIMING_CLOCK = 'clock_gettime(CLOCK_MONOTONIC_RAW)'


def elapsed_time():
    # CUDA worker is Linux-only. Fail rather than silently reverting to a disciplined clock.
    if not hasattr(time, 'CLOCK_MONOTONIC_RAW'):
        raise RuntimeError('CUDA profiling requires CLOCK_MONOTONIC_RAW')
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


def luminous_bounds(medium,shape):
    """Integer bounds of positive opacity, or None; zero-opacity cells exchange no radiation."""
    import torch
    nx,ny,nz=shape
    active=(medium[:,0]>0).reshape(nz,ny,nx)
    zs=active.any(dim=(1,2)).nonzero().flatten()
    if not zs.numel():return None
    xs=active.any(dim=(0,1)).nonzero().flatten()
    ys=active.any(dim=(0,2)).nonzero().flatten()
    return torch.stack([xs[0],ys[0],zs[0],xs[-1],ys[-1],zs[-1]]).cpu().tolist()


def run(folder, source_path, out, cache_dir=None, trace_columns=None, full_grid_cooling=False):
    worker_start=elapsed_time();adjusted_start=time.monotonic();timings={}
    import numpy as np
    import torch
    source=Path(source_path).read_text()
    meta,u=validate(folder,source)
    if Path(out).exists():
        raise ValueError('output folder already exists')
    trace_columns=trace_columns or []
    if len(trace_columns)>64 or len(set(trace_columns))!=len(trace_columns) or any(not isinstance(i,int) or i<0 or i>=meta['shape'][0]*meta['shape'][1] for i in trace_columns):
        raise ValueError('invalid trace column indices')
    compilation_source=source
    if trace_columns:
        from trace_columns import trace_source, FIELDS
        compilation_source+=trace_source(source)
    timings['importsAndValidationSeconds']=elapsed_time()-worker_start
    stage_start=elapsed_time()
    spec=importlib.util.spec_from_file_location('cuda_compile',Path(__file__).with_name('compile.py'))
    compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(compiler)
    capability=torch.cuda.get_device_capability()
    ptx=compiler.compile_ptx(compilation_source,f'compute_{capability[0]}{capability[1]}',cut_cells='terrain' in meta,cache_dir=cache_dir)
    timings['compileSeconds']=elapsed_time()-stage_start
    stage_start=elapsed_time()
    required=(77 if 'cooling' in meta else 65)*__import__('math').prod(meta['shape'])+36*meta['shape'][0]*meta['shape'][1]
    if 'terrain' in meta:
        required+=sum((Path(folder)/name).stat().st_size for name in meta['files'] if name.startswith('cut-'))
    free,_=torch.cuda.mem_get_info()
    if required>free*0.8:
        raise MemoryError(f'job needs at least {required} bytes, only {free} free; keep 20% headroom')
    torch.cuda.init(); anchor=torch.empty(1,device='cuda')
    driver=C.CDLL('libcuda.so.1')
    def check(code):
        if code:
            raise RuntimeError(f'CUDA driver error {code}')
    module=C.c_void_p();check(driver.cuModuleLoadData(C.byref(module),ptx))
    functions={}
    for name in ('cudaSweep','cudaPrepare','cudaMeasure','cudaFirstPhase','cudaCoolingClock','cudaCoolingReset','cudaCoolingMedium','cudaCoolingLines','cudaCoolingApply','cudaRedistribute'):
        f=C.c_void_p();check(driver.cuModuleGetFunction(C.byref(f),module,name.encode()));functions[name]=f
    if trace_columns:
        f=C.c_void_p();check(driver.cuModuleGetFunction(C.byref(f),module,b'cudaTraceColumns'));functions['cudaTraceColumns']=f
    def launch(name,buffers,count):
        values=[C.c_uint64(t.data_ptr()) for t in buffers]
        params=(C.c_void_p*len(values))(*(C.addressof(v) for v in values))
        check(driver.cuLaunchKernel(functions[name],(count+127)//128,1,1,128,1,1,0,
                                   C.c_void_p(torch.cuda.current_stream().cuda_stream),params,None))
    folder=Path(folder);nx,ny,nz=meta['shape'];count=nx*ny*nz
    def read(name,dtype,shape):
        a=np.frombuffer((folder/name).read_bytes(),dtype=dtype).copy().reshape(shape)
        return torch.from_numpy(a).to('cuda')
    state=read('state.bin','<f4',(count,5));other=state.clone()
    mask=read('mask.bin','u1',(count,))
    species=read('species.bin','<f4',(count,2));other_species=species.clone()
    peak=read('peak.bin','<f4',(count,));impulse=read('impulse.bin','<f4',(count,))
    if not all(torch.isfinite(t).all().item() for t in (state,species,peak,impulse)):
        raise ValueError('non-finite input buffers')
    if (state[:,0]<=0).any().item() or (species<0).any().item() or (mask>1).any().item():
        raise ValueError('invalid density, species or solid mask')
    Control=scalar_layout(source,'StepControl');control=Control();control.timeLimit=meta['duration']
    def blob(value):
        return torch.tensor(list(bytes(value)),dtype=torch.uint8,device='cuda')
    controls=blob(control);uniforms=blob(u)
    speed=torch.zeros(2,device='cuda',dtype=torch.int32)
    # Keep one immutable uniform buffer per axis: asynchronous launches must not see a later write.
    variants=[]
    for order in (meta['axes'],list(reversed(meta['axes']))):
        row=[]
        for i,axis in enumerate(order):
            v=type(u).from_buffer_copy(bytes(u));v.axis=axis;v.finalSweep=int(i==len(order)-1)
            row.append(blob(v))
        variants.append(row)
    columns=read('columns.bin','<f4',(nx*ny,4))
    records=read('records.bin','<f4',(nx*ny,4));opened=read('open.bin','<f4',(nx*ny,))
    if not torch.isfinite(columns).all().item() or not torch.isfinite(records).all().item() or not torch.isfinite(opened).all().item():
        raise ValueError('non-finite receiver state')
    if (columns[:,:2]!=columns[:,:2].floor()).any().item():
        raise ValueError('receiver indices must be integers')
    if ((columns[:,:2]<0)|(columns[:,:2]>=nz)).any().item() or ((columns[:,2]<0)|(columns[:,2]>1)).any().item():
        raise ValueError('receiver indices/weights outside grid')
    cooling=meta.get('cooling')
    if cooling:
        R=scalar_layout(source,'RadiationUniforms');r=R()
        for key,value in cooling.items():
            if key!='interval':setattr(r,key,value)
        radiation=blob(r);medium=torch.zeros((count,2),device='cuda');loss=torch.zeros(count,device='cuda')
        box=torch.tensor([0,0,0,0,nx-1,ny-1,nz-1,0],device='cuda',dtype=torch.int32)
        elapsed_cooling=torch.zeros(1,device='cuda')
        directions=[(1,0,0),(0,1,0),(0,0,1),(1,1,0),(1,-1,0),(1,0,1),(1,0,-1),
                    (0,1,1),(0,1,-1),(1,1,1),(1,1,-1),(1,-1,1),(1,-1,-1)]
        rays=[torch.tensor([*d,int(i==0)],device='cuda',dtype=torch.int32) for i,d in enumerate(directions)]
    terrain=meta.get('terrain')
    if terrain:
        cut_columns=read('cut-columns.bin','<i4',(-1,4));cut_records=read('cut-records.bin','<f4',(-1,4))
        cut_walls=read('cut-walls.bin','<f4',(-1,4));cut_defects=read('cut-defects.bin','<f4',(-1,4))
        cut_list=read('cut-list.bin','<i4',(-1,));cut_ceilings=read('cut-ceilings.bin','<i4',(-1,))
        cut_count=torch.tensor([terrain['cutColumnCount']],device='cuda',dtype=torch.int32)
        cut_buffers=[cut_columns,cut_records,cut_walls,cut_defects,cut_ceilings]
    else:
        dummy=torch.zeros(16,device='cuda',dtype=torch.uint8)
        cut_buffers=[dummy]*5
    if trace_columns:
        trace_indices=torch.tensor([len(trace_columns),*trace_columns],device='cuda',dtype=torch.int32)
        trace_values=torch.zeros((len(trace_columns),8),device='cuda',dtype=torch.float32)
        trace_rows=[];trace_times=[]
    def trace():
        if trace_columns:
            launch('cudaTraceColumns',[state,columns,records,opened,uniforms,trace_indices,trace_values,controls],len(trace_columns))
            trace_rows.append(trace_values.cpu().numpy().copy())
    launch('cudaFirstPhase',[state,controls,columns,records,opened,uniforms],nx*ny)
    trace()
    if trace_columns: trace_times.append(meta.get('startTime',0))
    launch('cudaMeasure',[state,mask,speed,uniforms],count)
    torch.cuda.synchronize()
    timings['deviceSetupAndUploadSeconds']=elapsed_time()-stage_start
    start=elapsed_time()
    steps=0;dt_history=[]
    cooling_intervals=empty_cooling=box_cell_sum=box_cell_max=0
    box_cell_min=count
    while steps<meta['steps']:
        ramp=min(1.,float(np.float32((meta.get('startStep',0)+steps+1)/meta.get('startupSteps',1))))
        prepared=type(u).from_buffer_copy(bytes(u));prepared.cfl=np.float32(u.cfl)*np.float32(ramp)
        prepare_uniforms=blob(prepared)
        launch('cudaPrepare',[controls,speed,prepare_uniforms],1)
        for variant in variants[(meta.get('startStep',0)+steps)%2]:
            launch('cudaSweep',[state,other,mask,peak,impulse,controls,speed,variant,species,other_species,*cut_buffers],count)
            state,other=other,state;species,other_species=other_species,species
        if terrain and terrain['cutColumnCount']:
            launch('cudaRedistribute',[state,species,cut_columns,cut_records,uniforms,controls,peak,speed,
                                      cut_defects,cut_list,cut_count,mask],terrain['cutColumnCount'])
        if cooling:
            launch('cudaCoolingClock',[controls,elapsed_cooling],1)
            if (meta.get('startStep',0)+steps+1)%cooling['interval']==0:
                launch('cudaCoolingMedium',[state,mask,species,uniforms,radiation,medium],count)
                cooling_intervals+=1
                edges=[0,0,0,nx-1,ny-1,nz-1] if full_grid_cooling else luminous_bounds(medium,(nx,ny,nz))
                cells=0
                if edges is not None:
                    lowx,lowy,lowz,highx,highy,highz=edges
                    cells=(highx-lowx+1)*(highy-lowy+1)*(highz-lowz+1)
                    if not full_grid_cooling:
                        box.copy_(torch.tensor([lowx,lowy,lowz,0,highx,highy,highz,0],device='cuda',dtype=torch.int32))
                    for ray in rays:
                        launch('cudaCoolingLines',[medium,mask,loss,box,uniforms,ray],count)
                    launch('cudaCoolingApply',[state,medium,loss,box,elapsed_cooling,uniforms,radiation,controls],count)
                else:
                    empty_cooling+=1
                box_cell_sum+=cells;box_cell_min=min(box_cell_min,cells);box_cell_max=max(box_cell_max,cells)
                launch('cudaCoolingReset',[controls,elapsed_cooling],1)
        launch('cudaFirstPhase',[state,controls,columns,records,opened,uniforms],nx*ny)
        trace()
        torch.cuda.synchronize()
        control=Control.from_buffer_copy(controls.cpu().numpy().tobytes())
        if control.stopped==3:
            raise RuntimeError('nonphysical wave speed; no completed dataset written')
        if control.dt>0:
            steps+=1;dt_history.append(control.dt)
        if trace_columns: trace_times.append(meta.get('startTime',0)+sum(dt_history))
        if control.stopped==2:
            break
        if control.stopped==1:
            control.stopped=0;control.stepIndex=0;control.batchTime=0
            control.timeLimit=max(meta['duration']-sum(dt_history),0)
            controls.copy_(blob(control))
    elapsed=elapsed_time()-start
    timings['solverSeconds']=elapsed
    stage_start=elapsed_time()
    if steps==meta['steps'] and sum(dt_history) < meta['duration']*(1-1e-4):
        raise RuntimeError('step limit reached before duration; no completed dataset written')
    if not all(torch.isfinite(t).all().item() for t in (state,species,peak,impulse,records)):
        raise RuntimeError('non-finite output; no completed dataset written')
    out=Path(out);out.mkdir(parents=True)
    for name,tensor in [('state',state),('species',species),('peak',peak),('impulse',impulse),('first-phase',records)]:
        tensor.cpu().numpy().astype('<f4').tofile(out/(name+'.bin'))
    if trace_columns:
        np.save(out/'trace.npy',np.stack(trace_rows))
        (out/'trace.json').write_text(json.dumps({'columns':trace_columns,'fields':FIELDS,'times':trace_times,
            'sampling':'after first-phase recording, including initial sample; read-only diagnostic kernel; timing is perturbed'},indent=2)+'\n')
    np.save(out/'dt.npy',np.array(dt_history,dtype='<f4'))
    # Match the dataset's field channels: interpolate the accumulated fields, not instantaneous peaks.
    def plane(field):
        a=field.reshape(nz,ny,nx)
        c=columns.cpu().numpy()
        lo=torch.tensor(c[:,0].astype('int64'),device='cuda').reshape(ny,nx)
        hi=torch.tensor(c[:,1].astype('int64'),device='cuda').reshape(ny,nx)
        w=columns[:,2].reshape(ny,nx)
        low=torch.gather(a,0,lo.unsqueeze(0))[0]
        high=torch.gather(a,0,hi.unsqueeze(0))[0]
        return ((1-w)*low+w*high).cpu().numpy()
    target=np.stack([plane(peak),plane(impulse)])
    valid=(columns[:,3]>0).reshape(ny,nx).cpu().numpy()
    np.save(out/'targets.npy',target.astype('<f4'))
    np.save(out/'firstPhaseImpulse.npy',records[:,2].reshape(ny,nx).cpu().numpy().astype('<f4'))
    np.save(out/'mask.npy',valid.astype('<f4'))
    report={'format':'bombcad-cuda-result-1','backend':'cuda','terrainCutCells':bool(terrain),'device':torch.cuda.get_device_name(),
            'sourceSHA256':hashlib.sha256(source.encode()).hexdigest(),'steps':steps,
            'startTime':meta.get('startTime',0),'elapsedSimulationTime':sum(dt_history),
            'wallSeconds':elapsed,'shape':meta['shape'],'math':'float32, unfused, precise division/sqrt',
            'workerFilesSHA256':{name:hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in ('run.py','job.py','compile.py')},
            'channels':['peakOverpressure','impulse'],'units':['Pa','Pa s'],'above':meta.get('above',2)}
    if 'dataset' in meta:
        import shutil
        dataset=out/'dataset';dataset.mkdir()
        details=json.loads((folder/'meta.json').read_text())
        keep=np.load(folder/'mask.npy',allow_pickle=False)
        if keep.shape!=(ny,nx):
            raise ValueError('dataset template mask shape mismatch')
        channels=[target[0],target[1]]
        if len(details['targets'])==3:
            channels.append(records[:,2].reshape(ny,nx).cpu().numpy())
        full=np.stack(channels).astype('<f4');full[:,keep==0]=0
        np.save(dataset/'targets.npy',full)
        shutil.copyfile(folder/'inputs.npy',dataset/'inputs.npy')
        shutil.copyfile(folder/'mask.npy',dataset/'mask.npy')
        details.update(stable=True,steps=steps,untilS=meta.get('startTime',0)+sum(dt_history),wallS=elapsed)
        details['configuration']=details['configuration'].replace('; awaiting CUDA','; CUDA uniform')
        details['cudaProvenance']=report
    timings['validationAndOutputSeconds']=elapsed_time()-stage_start
    timings['workerSecondsBeforeManifests']=elapsed_time()-worker_start
    if trace_columns:
        report['workerFilesSHA256']['trace_columns.py']=hashlib.sha256(Path(__file__).with_name('trace_columns.py').read_bytes()).hexdigest()
        report['traceColumns']=trace_columns
        report['diagnosticSourceSHA256']=hashlib.sha256(compilation_source.encode()).hexdigest()
    report['coolingWorkSelection']='disabled' if not cooling else ('full-grid' if full_grid_cooling else 'luminous-box')
    report['coolingWork']={'intervals':cooling_intervals,'emptyIntervals':empty_cooling,
        'minBoxCells':box_cell_min if cooling_intervals else 0,'maxBoxCells':box_cell_max,
        'meanBoxCells':box_cell_sum/cooling_intervals if cooling_intervals else 0}
    report['compileCacheEnabled']=cache_dir is not None
    report['timingClock']=TIMING_CLOCK
    report['clockAudit']={'rawSeconds':elapsed_time()-worker_start,
                          'adjustedMonotonicSeconds':time.monotonic()-adjusted_start}
    report['timings']=timings
    report['timingScope']='Raw host elapsed time (not disciplined monotonic); compile includes device capability query; setup includes module load, upload and initial kernels; output includes final validation and array writes; excludes manifest writes and module unload'
    if 'dataset' in meta:
        (dataset/'meta.json').write_text(json.dumps(details,indent=2)+'\n')
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    check(driver.cuModuleUnload(module))
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('job',type=Path);p.add_argument('--source',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--lock',type=Path,help='shared remote-train lock directory')
    from trace_columns import parse_columns
    p.add_argument('--trace-columns',type=parse_columns,help='opt-in read-only traces for up to 64 flattened plan indices')
    p.add_argument('--full-grid-cooling',action='store_true',help='diagnostic fallback: integrate cooling over the full grid')
    p.add_argument('--cache-dir',type=Path,help='opt-in content-addressed NVRTC PTX cache')
    a=p.parse_args()
    lock_module=None
    if a.lock:
        helper=Path(__file__).with_name('remote-train.py')
        if not helper.exists():helper=Path(__file__).parent.parent/'ml/remote-train.py'
        spec=importlib.util.spec_from_file_location('remote_train_lock',helper)
        lock_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(lock_module)
        if not lock_module.acquire(str(a.lock),f'CUDA dataset {a.job}',lock_module.boot_id()):
            raise SystemExit('PC GPU is held by another job; retry after it finishes')
    try:
        print(json.dumps(run(a.job,a.source,a.out,a.cache_dir,a.trace_columns,a.full_grid_cooling),indent=2))
    finally:
        if lock_module:lock_module.release(str(a.lock))
