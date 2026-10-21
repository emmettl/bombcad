#!/usr/bin/env python3
"""Run an explicit production math-mode × contraction × execution-path experiment.

No defaults or acceptance thresholds are changed. Uses existing field-run cases,
local inputs, compiler probes and gpu-slot. These traced runs measure numerical
sensitivity, not performance. `contract=on` permits fusion; it does not attest
machine instructions. A completed experiment may still fail production gates.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
from compare_dataset import compare

ROOT=Path(__file__).resolve().parents[2]
PROBES=('BOMBCAD_KERNEL_MATH','BOMBCAD_KERNEL_CONTRACT','BOMBCAD_STATE_PADDING',
        'BOMBCAD_STATE_PADDING_AT','BOMBCAD_KERNEL_PERTURB')
MODES={'fast-on':('fast','on'),'fast-off':('fast','off'),
       'safe-on':('safe','on'),'safe-off':('safe','off'),
       'default-off':(None,'off'),'fast-default':('fast',None)}
FACTORIAL=('fast-on','fast-off','safe-on','safe-off')


def module(path,name):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
    return h.hexdigest()


def selection(text,allowed):
    values=text.split(',')
    if not values or len(set(values))!=len(values) or any(v not in allowed for v in values):
        raise argparse.ArgumentTypeError('choose distinct comma-separated values from '+','.join(allowed))
    return values


def execute(command,cwd,env,log,timeout):
    process=subprocess.Popen(command,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        code=process.wait(timeout=timeout)
        if code:raise subprocess.CalledProcessError(code,command)
    except BaseException:
        for action in (signal.SIGTERM,signal.SIGKILL):
            try:os.killpg(process.pid,action)
            except ProcessLookupError:pass
            if action==signal.SIGTERM:
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:pass
        process.wait()
        raise


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case',required=True)
    p.add_argument('--scenebench',type=Path,required=True)
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--columns',required=True,help='up to 64 distinct enabled flattened receiver indices')
    p.add_argument('--modes',default=','.join(FACTORIAL),type=lambda s:selection(s,MODES))
    p.add_argument('--paths',default='tiled,full',type=lambda s:selection(s,('tiled','full')))
    p.add_argument('--timeout',type=int,default=5400,help='seconds per variant, including gpu-slot waiting')
    p.add_argument('--dry-run',action='store_true')
    a=p.parse_args()
    from trace_columns import parse_columns
    try:columns=parse_columns(a.columns)
    except argparse.ArgumentTypeError as e:p.error(str(e))
    if a.timeout<=0:p.error('timeout must be positive')
    if a.out.exists():p.error('output root must be new')
    binary=a.scenebench.resolve();reference=a.reference.resolve();out=a.out.resolve()
    if not binary.is_file():p.error('scenebench must be built first')
    if not all((reference/name).is_file() for name in ('inputs.npy','mask.npy','targets.npy','meta.json')):
        p.error('complete production reference required')
    reference_meta=json.loads((reference/'meta.json').read_text())
    if reference_meta.get('id')!=a.case or not reference_meta.get('stable') or len(reference_meta.get('targets',[]))!=3:
        p.error('reference must be this case with three stable target channels')
    field=module(ROOT/'Scripts/ml/field-runs.py','matrix_field_runs')
    plan=json.loads(Path(field.LIST).read_text())
    run=next((r for rows in plan['sets'].values() for r in rows if r['id']==a.case),None)
    if run is None:p.error('case absent from field-runs plan')
    layout=plan['layouts'][run['layout']]
    inputs=field.inputs_for(run['layout'],layout,make=False)
    if any(inputs.get(k) and not Path(inputs[k]).is_file() for k in ('osm','dem','heights')):
        p.error('prepared layout inputs required; matrix does not generate layouts')
    input_hashes={k:digest(inputs[k]) for k in ('osm','dem','heights') if inputs.get(k)}
    variants=[(mode,path) for mode in a.modes for path in a.paths]
    source_files=sorted((ROOT/'Sources/BlastCore').rglob('*.swift'))+sorted((ROOT/'Sources/BlastCore/Shaders').glob('*.metal'))
    source_files += sorted((ROOT/'Sources/SceneBench').glob('*.swift'))+sorted((ROOT/'Sources/BlastModel').glob('*.swift'))
    source_files += [ROOT/'Scripts/ml/field-runs.py',ROOT/'Scripts/ml/field-runs.json']
    source_hashes={str(path.relative_to(ROOT)):digest(path) for path in source_files}
    resources=[path for bundle in binary.parent.glob('*.bundle') for path in bundle.rglob('*.metal')]
    if not resources:p.error('no bundled Metal sources found beside executable')
    resource_hashes={str(path.relative_to(binary.parent)):digest(path) for path in sorted(resources)}
    binary_hash=digest(binary)
    reference_hashes={name:digest(reference/name) for name in ('inputs.npy','mask.npy','targets.npy','meta.json')}
    environment={k:v for k,v in os.environ.items() if k not in PROBES}
    contract={'format':'bombcad-math-matrix-1','case':a.case,'columns':columns,
              'variantOrder':[mode+'-'+path for mode,path in variants],
              'scenebenchSHA256':binary_hash,'sourceObservationsSHA256':source_hashes,
              'runtimeMetalResourcesSHA256':resource_hashes,
              'layoutInputSHA256':input_hashes,
              'referenceSHA256':reference_hashes,'probeKeysReset':list(PROBES),
              'scope':'Explicit requested math/contraction settings; traced numerical experiment, not timing benchmark; no machine-instruction attestation',
              'gitRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
              'runnerSHA256':digest(__file__)}
    if a.dry_run:print(json.dumps(contract,indent=2));return
    out.mkdir(parents=True)
    def status(state,**extra):
        temporary=out/'status.tmp'
        temporary.write_text(json.dumps({'state':state,**extra},indent=2)+'\n')
        temporary.replace(out/'status.json')
    (out/'runner-source.py').write_bytes(Path(__file__).read_bytes())
    (out/'contract.json').write_text(json.dumps(contract,indent=2)+'\n')
    def verify_inputs():
        if digest(binary)!=binary_hash or any(digest(ROOT/name)!=h for name,h in source_hashes.items()):
            raise RuntimeError('executable or observed sources changed during experiment')
        if any(digest(binary.parent/name)!=h for name,h in resource_hashes.items()):
            raise RuntimeError('runtime Metal resources changed during experiment')
        if any(digest(inputs[k])!=h for k,h in input_hashes.items()):
            raise RuntimeError('layout inputs changed during experiment')
        if any(digest(reference/name)!=h for name,h in reference_hashes.items()):
            raise RuntimeError('reference changed during experiment')
    rows=[];started=time.time();status('running',completed=[])
    audit=module(ROOT/'Scripts/cuda/diagnose-production.py','matrix_production_audit')
    def terminated(signum,frame):
        raise KeyboardInterrupt('terminated')
    previous_handler=signal.signal(signal.SIGTERM,terminated)
    try:
        for mode,path in variants:
            verify_inputs()
            name=mode+'-'+path;folder=out/name
            math,contraction=MODES[mode]
            env=dict(environment,BOMBCAD_SOURCE_REVISION=contract['gitRevision'])
            for key,value in zip(PROBES[:2],(math,contraction)):
                if value is not None:env[key]=value
            command=[field.GPU_SLOT,'--mem',str(run['estimate']['memGB']),str(binary)]
            command+=field.field_arguments(run,layout,inputs,str(folder))
            command+=['--first-phase','--trace-columns',','.join(str(i) for i in columns)]
            if path=='full':command+=['--full-grid-diagnostic']
            receipt={'mode':mode,'path':path,'environment':{k:env.get(k) for k in PROBES[:2]},'command':command,
                     'executableSHA256':binary_hash,'startUTC':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
            (out/(name+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n')
            print('RUN '+name,flush=True)
            with (out/(name+'.log')).open('w') as log:
                execute(command,ROOT,env,log,a.timeout)
            verify_inputs()
            report=audit.summarize(folder,reference)
            (folder/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
            rows.append({'variant':name,'environment':receipt['environment'],
                         'arraySHA256':report['arraySHA256'],'referenceComparison':report['comparison'],
                         'arraysBitIdenticalToReference':report['arraysBitIdenticalToOriginal']})
            status('running',completed=[r['variant'] for r in rows]);print('DONE '+name,flush=True)
        pairs={}
        for mode in a.modes:
            if {'tiled','full'}<=set(a.paths):
                tiled=next(r for r in rows if r['variant']==mode+'-tiled')
                full=next(r for r in rows if r['variant']==mode+'-full')
                pairs[mode]={'arraysBitIdentical':tiled['arraySHA256']==full['arraySHA256'],
                             'comparison':compare(out/(mode+'-tiled'),out/(mode+'-full'))}
        matrix={**contract,'rows':rows,'withinModeTiledVsFull':pairs,
                'allVariantsPassOriginalReference':all(r['referenceComparison']['passed'] for r in rows)}
        (out/'matrix.json').write_text(json.dumps(matrix,indent=2)+'\n')
        status('complete',completed=[r['variant'] for r in rows],elapsedWallSeconds=time.time()-started,
               acceptancePassed=matrix['allVariantsPassOriginalReference'])
    except BaseException as error:
        status('failed',completed=[r['variant'] for r in rows],error=str(error));raise
    finally:
        signal.signal(signal.SIGTERM,previous_handler)


if __name__=='__main__':main()
