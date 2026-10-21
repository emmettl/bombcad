#!/usr/bin/env python3
"""Bounded, resumable reference-replay field queue on production Metal and generated CUDA.

One controller plans work; independent case workers hold leases and publish gated,
content-addressed objects. Interrupting the controller leaves live workers running.
Resume observes their leases/process groups instead of launching them again. No training
index or bulk field plan is modified. Plans and all executable/input/reference identities
are immutable for a queue; use a new queue after changing them.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid
from compare_dataset import compare, npy
from generate import generate
from job import validate
import remote

FORMAT='bombcad-field-queue-1'
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
VALUES={'osm','dem','heights','centre','radius','dx','height','mass','ground','id','layout','until','above','edge'}
FLAGS={'first-phase','balloon'}
FILES={'osm','dem','heights'}
PROBES=('BOMBCAD_KERNEL_MATH','BOMBCAD_KERNEL_CONTRACT','BOMBCAD_STATE_PADDING',
        'BOMBCAD_STATE_PADDING_AT','BOMBCAD_KERNEL_PERTURB')
SLOT_ENV=('BOMBCAD_GPU_SLOTS','BOMBCAD_GPU_SLOT_DIR','BOMBCAD_GPU_MEM_BUDGET')
DATA_FILES=('inputs.npy','mask.npy','targets.npy','meta.json')
PHYSICS={'recommended-uniform','recommended-static-terrain'}
INPUT_NAMES=['height','ground','distance','logScaledDistance','kingeryBulmashPeak','kingeryBulmashImpulse']
TARGET_NAMES=['peakOverpressure','impulse','firstPhaseImpulse']
_BOOT=None
_CHILDREN=[]


def boot_id():
    global _BOOT
    if _BOOT is None:
        path=Path('/proc/sys/kernel/random/boot_id')
        if path.exists():_BOOT=path.read_text().strip()
        else:
            value=subprocess.check_output(['sysctl','-n','kern.bootsessionuuid'],text=True).strip()
            if not re.fullmatch('[0-9A-Fa-f-]{36}',value):raise ValueError('boot identity unavailable')
            _BOOT='mac-'+value
    return _BOOT


class GateFailure(ValueError):pass
class Deferred(RuntimeError):pass


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def address(value):return hashlib.sha256(canonical(value)).hexdigest()
def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1048576),b''):h.update(block)
    return h.hexdigest()


def sync_directory(path):
    fd=os.open(path,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def atomic(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    with tmp.open('wb') as f:f.write(canonical(value)+b'\n');f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)
    sync_directory(path.parent)


def read(path):return json.loads(Path(path).read_text())
def strict(value,allowed,required):
    if not isinstance(value,dict) or set(value)-set(allowed) or set(required)-set(value):
        raise ValueError('invalid fields: '+str(value.keys() if isinstance(value,dict) else type(value)))


def arguments(tokens,reference=False):
    if not isinstance(tokens,list) or any(not isinstance(t,str) for t in tokens):raise ValueError('arguments must be strings')
    result={};i=0
    while i<len(tokens):
        flag=tokens[i];i+=1
        if not flag.startswith('--'):raise ValueError('expected field option: '+flag)
        key=flag[2:]
        if reference and key in ('out','cuda-source'):
            if i==len(tokens):raise ValueError('missing reference option value')
            i+=1;continue
        if reference and key in ('cuda-job','phase-timings'):continue
        if key not in VALUES|FLAGS or key in result:raise ValueError('unsupported or duplicate field option: '+flag)
        if key in FLAGS:result[key]=True;continue
        if i==len(tokens) or tokens[i].startswith('--'):raise ValueError('missing field option value: '+flag)
        result[key]=str(Path(tokens[i]).resolve()) if key in FILES else tokens[i];i+=1
    if not {'osm','id'}<=set(result):raise ValueError('explicit --osm and --id required')
    for key in ('radius','dx','height','mass','until','above','edge'):
        if key in result:
            number=float(result[key])
            if not math.isfinite(number) or number<0 or (key not in ('above','edge') and number==0):raise ValueError('invalid numeric option: '+key)
            if key=='edge' and not re.fullmatch(r'[0-9]+',result[key]):raise ValueError('integer edge required')
    if 'centre' in result:
        lon,lat=map(float,result['centre'].split(','))
        if not -180<=lon<=180 or not -90<=lat<=90:raise ValueError('invalid centre')
    return result


def costs(terms,pins):
    if not isinstance(terms,list) or not terms:raise ValueError('measured cost terms required')
    total=0.
    for term in terms:
        strict(term,('report','keys'),('report','keys'))
        path=Path(term['report']).resolve();pins[str(path)]=digest(path);value=read(path)
        if not isinstance(term['keys'],list):raise ValueError('cost keys must be a list')
        for key in term['keys']:value=value[key]
        if type(value) not in (int,float) or not math.isfinite(value) or value<0:raise ValueError('cost evidence must resolve to finite seconds')
        total+=value
    if total<=0:raise ValueError('positive total cost required')
    return total


def clean_env(contract):
    env=dict(os.environ)
    for key in (*PROBES,*SLOT_ENV,'BOMBCAD_GPU_MEM_FORCE'):
        env.pop(key,None)
    for key in list(env):
        if key.startswith('GPU_SLOT_'):env.pop(key)
    env.update(contract['slotEnvironment'])
    env['BOMBCAD_SOURCE_REVISION']=contract['revisionObservedAtInit']+('-dirty' if contract['worktreeDirtyAtInit'] else '')
    return env


def field_metadata(folder,args):
    meta=read(Path(folder)/'meta.json')
    targets=TARGET_NAMES if args.get('first-phase') else TARGET_NAMES[:2]
    if meta.get('format')!='bombcad-field-1' or meta.get('stable') is not True:raise ValueError('stable field format 1 required')
    for key,names in (('inputs',INPUT_NAMES),('targets',targets)):
        items=meta.get(key)
        if not isinstance(items,list) or any(not isinstance(x,dict) for x in items) or [x.get('name') for x in items]!=names:raise ValueError('field channel semantics differ: '+key)
        if npy(Path(folder)/(key+'.npy'))[0]!=(len(names),meta['rows'],meta['columns']):raise ValueError('field shape differs: '+key)
    if npy(Path(folder)/'mask.npy')[0]!=(meta['rows'],meta['columns']):raise ValueError('field mask shape differs')
    if arguments(meta.get('arguments'),reference=True)!=args:raise ValueError('reference command does not match requested field physics/inputs')
    return meta


def build_contract(plan):
    strict(plan,('format','purpose','scenebench','gpuSlot','cuda','jobs','maxAttempts'),('format','purpose','scenebench','jobs'))
    if plan['format']!=FORMAT or plan['purpose']!='reference-replay':raise ValueError('only explicit reference-replay plans are admitted')
    jobs=plan['jobs']
    if not isinstance(jobs,list) or not 1<=len(jobs)<=8:raise ValueError('bounded replay queue requires 1–8 jobs')
    max_attempts=plan.get('maxAttempts',3)
    if type(max_attempts) is not int or not 1<=max_attempts<=5:raise ValueError('maxAttempts must be 1–5')
    pins={};exe=Path(plan['scenebench']).resolve();slot=Path(plan.get('gpuSlot',Path.home()/'.local/bin/gpu-slot')).resolve()
    for path in (exe,slot):
        if not os.access(path,os.X_OK):raise ValueError('executable unavailable: '+str(path))
        pins[str(path)]=digest(path)
    for bundle in exe.parent.glob('*.bundle'):
        for path in bundle.rglob('*'):
            if path.is_file():pins[str(path.resolve())]=digest(path)
    for name in ('field-queue.py','remote.py','run.py','job.py','compile.py','generate.py','trace_columns.py','compare_dataset.py','entry.cuh','compat.cuh'):
        path=HERE/name;pins[str(path)]=digest(path)
    lock_helper=HERE.parent/'ml/remote-train.py';pins[str(lock_helper)]=digest(lock_helper)
    cuda=plan.get('cuda')
    if cuda is not None:
        strict(cuda,('host','python','cacheDir'),('host',))
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',cuda['host']):raise ValueError('invalid CUDA SSH alias')
        for key in ('python','cacheDir'):
            if key in cuda and (not re.fullmatch(r'[A-Za-z0-9_./-]+',cuda[key]) or '..' in Path(cuda[key]).parts):raise ValueError('invalid remote path')
    normalized=[];ids=set()
    for job in jobs:
        strict(job,('id','arguments','reference','physics','backends','metalGB','cudaBytes','costs','cachedCudaCosts','timeoutSeconds'),
               ('id','arguments','reference','physics','backends','metalGB','costs'))
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}',job['id']) or job['id'] in ids:raise ValueError('invalid or duplicate case id')
        ids.add(job['id']);args=arguments(job['arguments'])
        if args['id']!=job['id']:raise ValueError('case id and --id differ')
        if job['physics'] not in PHYSICS:raise ValueError('unsupported field physics: '+job['physics'])
        expected='recommended-static-terrain' if 'dem' in args else 'recommended-uniform'
        if job['physics']!=expected:raise ValueError('declared geometry and field inputs differ')
        modes=job['backends']
        if not isinstance(modes,list) or not modes or len(set(modes))!=len(modes) or set(modes)-{'metal','cuda'}:raise ValueError('invalid backends')
        if 'cuda' in modes and cuda is None:raise ValueError('CUDA backend needs host configuration')
        for key in FILES&set(args):pins[args[key]]=digest(args[key])
        ref=Path(job['reference']).resolve();meta=field_metadata(ref,args)
        if meta.get('stable') is not True or meta.get('cudaProvenance') is not None or meta.get('configuration')!=('recommended, balloon start' if args.get('balloon') else 'recommended'):raise ValueError('stable production Metal reference required')
        if arguments(meta.get('arguments'),reference=True)!=args:raise ValueError('reference command does not match requested field physics/inputs')
        if len(meta['targets'])!=(3 if args.get('first-phase') else 2):raise ValueError('reference target channels differ')
        for name in DATA_FILES:pins[str(ref/name)]=digest(ref/name)
        shape,_=npy(ref/'targets.npy')
        if shape!=(len(meta['targets']),meta['rows'],meta['columns']):raise ValueError('reference shape differs from metadata')
        if not compare(ref,ref)['passed']:raise ValueError('invalid reference')
        mem=job['metalGB'];minimum=max(.5,1.25*meta['solverBytes']/1e9+.25)
        if type(mem) not in (int,float) or not math.isfinite(mem) or mem<minimum:raise ValueError('Metal declaration below reference memory bound')
        cbytes=job.get('cudaBytes',0)
        if 'cuda' in modes and (type(cbytes) is not int or cbytes<77*meta['cells']+36*meta['rows']*meta['columns']):raise ValueError('CUDA declaration below portable memory bound')
        strict(job['costs'],modes,modes)
        estimated={mode:costs(job['costs'][mode],pins) for mode in modes}
        cached_cost=None
        if 'cachedCudaCosts' in job:
            if 'cuda' not in modes:raise ValueError('cached CUDA cost requires CUDA backend')
            cached_cost=costs(job['cachedCudaCosts'],pins)
        timeout=job.get('timeoutSeconds',600)
        if type(timeout) not in (int,float) or not math.isfinite(timeout) or not max([*estimated.values(),cached_cost or 0])<timeout<=86400:raise ValueError('timeout must exceed estimated cost and be at most one day')
        normalized_args=[token for k,v in args.items() for token in (['--'+k] if v is True else ['--'+k,v])]
        item=dict(job,arguments=normalized_args,reference=str(ref),estimatedSeconds=estimated,cudaBytes=cbytes,timeoutSeconds=timeout)
        if cached_cost is not None:item['cachedCudaEstimatedSeconds']=cached_cost
        item['key']=address({'job':item,'referenceHashes':{n:pins[str(ref/n)] for n in DATA_FILES}});normalized.append(item)
    contract={'format':FORMAT,'machine':platform.node(),'purpose':plan['purpose'],'scenebench':str(exe),'gpuSlot':str(slot),
              'cuda':cuda,'maxAttempts':max_attempts,'jobs':normalized,'filesSHA256':pins,
              'numericalSourceSHA256':hashlib.sha256(generate().encode()).hexdigest(),
              'slotEnvironment':{k:os.environ[k] for k in SLOT_ENV if k in os.environ},
              'worktreeDirtyAtInit':bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True).strip()),
              'revisionObservedAtInit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()}
    contract['key']=address(contract);return contract


def verify_contract(contract):
    if contract['machine']!=platform.node():raise ValueError('queue belongs to another controller host')
    check=dict(contract);key=check.pop('key')
    if address(check)!=key:raise ValueError('queue contract changed')
    for name,expected in contract['filesSHA256'].items():
        if digest(name)!=expected:raise ValueError('pinned file changed: '+name)
    if hashlib.sha256(generate().encode()).hexdigest()!=contract['numericalSourceSHA256']:raise ValueError('generated physics changed')


def init(plan,root):
    root=Path(root).resolve()
    contract=build_contract(plan)
    if root.exists():raise ValueError('queue directory must be new')
    root.mkdir(parents=True);(root/'objects').mkdir();(root/'cases').mkdir()
    atomic(root/'contract.json',contract)
    for job in contract['jobs']:(root/'cases'/job['key']/'attempts').mkdir(parents=True)
    return contract


@contextlib.contextmanager
def lease(path):
    f=Path(path).open('a+')
    try:
        try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:yield None;return
        yield f
    finally:f.close()


def group_alive(pid):
    # Zombies are terminal; a live descendant still counts after its session leader exits.
    text=subprocess.check_output(['ps','-axo','pgid=,stat='],text=True)
    return any(int(parts[0])==pid and not parts[1].startswith('Z') for line in text.splitlines()
               if len(parts:=line.split())>=2)


def process_snapshot(pid):
    env=dict(os.environ,LC_ALL='C',TZ='UTC')
    r=subprocess.run(['ps','-ww','-p',str(pid),'-o','lstart=','-o','stat=','-o','command='],capture_output=True,text=True,env=env)
    parts=r.stdout.strip().split(None,6)
    return {'birth':' '.join(parts[:5]),'state':parts[5],'command':parts[6]} if r.returncode==0 and len(parts)==7 else None


def tracked_alive(process):
    if process['boot']!=boot_id():return False
    leader=process_snapshot(process['pid'])
    if leader is not None and not leader.get('state','').startswith('Z'):
        # Command nonce identifies this launch even if wall-clock correction changes ps lstart.
        if process['attempt'] not in leader['command'] or process['queue'] not in leader['command'] or '_worker' not in leader['command']:return False
    return group_alive(process['pgid'])


def object_receipt(root,ident,contract,job):
    if not re.fullmatch('[0-9a-f]{64}',ident):raise ValueError('invalid object address')
    folder=root/'objects'/ident;receipt=read(folder/'receipt.json')
    if address(receipt)!=ident or receipt['contract']!=contract['key'] or receipt['case']!=job['key']:raise ValueError('object identity differs')
    for name,h in receipt['filesSHA256'].items():
        if name not in DATA_FILES or digest(folder/'dataset'/name)!=h:raise ValueError('accepted output corrupted')
    if set(receipt['filesSHA256'])!=set(DATA_FILES) or not compare(job['reference'],folder/'dataset')['passed']:raise ValueError('accepted gate no longer passes')
    if receipt['backend'] not in job['backends'] or receipt['provenance']['backend']!=receipt['backend']:raise ValueError('accepted backend differs')
    provenance=receipt['provenance']
    if receipt['backend']=='metal':
        if provenance['executableSHA256']!=contract['filesSHA256'][contract['scenebench']]:raise ValueError('accepted executable differs')
    else:
        result=provenance['result']
        expected={name:contract['filesSHA256'][str(HERE/name)] for name in ('run.py','job.py','compile.py')}
        if result['sourceSHA256']!=contract['numericalSourceSHA256'] or result['workerFilesSHA256']!=expected:raise ValueError('accepted worker differs')
    return receipt


def recover(root,contract):
    # Recover publication after a controller/worker died between object rename and pointer write.
    for folder in sorted((root/'objects').iterdir()):
        if not folder.is_dir():raise ValueError('unexpected object entry')
        receipt=read(folder/'receipt.json');job=next((j for j in contract['jobs'] if j['key']==receipt.get('case')),None)
        if job is None:raise ValueError('unknown published case')
        object_receipt(root,folder.name,contract,job)
        pointer=root/'cases'/job['key']/'accepted.json'
        if pointer.exists() and read(pointer)['object']!=folder.name:raise ValueError('multiple accepted objects for case')
        if not pointer.exists():atomic(pointer,{'object':folder.name})


def case_state(root,contract,job):
    root=Path(root).resolve()
    folder=root/'cases'/job['key'];pointer=folder/'accepted.json'
    if pointer.exists():
        ident=read(pointer)['object'];object_receipt(root,ident,contract,job)
        return {'status':'accepted','object':ident,'attempts':len(list((folder/'attempts').iterdir()))}
    attempts=[];active=[];blocked=set();failures={m:0 for m in job['backends']};retry_after=0.
    generation=read(folder/'retry.json')['generation'] if (folder/'retry.json').exists() else 0
    for attempt in sorted((folder/'attempts').iterdir()):
        request=read(attempt/'request.json');result=read(attempt/'result.json') if (attempt/'result.json').exists() else None
        process=read(attempt/'process.json') if (attempt/'process.json').exists() else read(attempt/'launch.json') if (attempt/'launch.json').exists() else None
        if process and (type(process.get('pid')) is not int or process['pid']<=0 or process.get('pgid')!=process['pid'] or not isinstance(process.get('boot'),str) or process.get('attempt')!=attempt.name or process.get('queue')!=str(root)):raise ValueError('invalid worker process identity')
        with lease(attempt/'active.lock') as held:locked=held is None
        if locked or (process and tracked_alive(process)) or (not process and not result and time.time()-request['createdAt']<2):
            active.append({'attempt':attempt.name,'backend':request['backend'],'startedAt':request['createdAt'],
                           'estimatedSeconds':request.get('decision',{}).get('estimatedSeconds',job['estimatedSeconds'][request['backend']]), 'process':process})
        elif result and result['status']=='blocked':blocked.add(request['backend'])
        elif not result or result['status']=='failed':
            if request.get('generation',0)==generation:failures[request['backend']]+=1
            retry_after=max(retry_after,request['createdAt']+2)
        elif result['status']=='deferred':retry_after=max(retry_after,result['finishedAt']+2)
        attempts.append({'id':attempt.name,'backend':request['backend'],'result':result})
    modes=[m for m in job['backends'] if m not in blocked and failures[m]<contract['maxAttempts']]
    prepared=None
    if not active and 'cuda' in modes and (folder/'prepared').exists():
        prepared=verify_prepared(folder/'prepared',contract,job)
    return {'status':'running' if active else 'pending' if modes else 'failed','active':active,
            'preparationCache':prepared,
            'eligibleBackends':modes,'blockedBackends':sorted(blocked),'failureCounts':failures,
            'attempts':len(attempts),'retryAfter':retry_after,'history':attempts}


def mac_snapshot(contract):
    try:return _mac_snapshot(contract)
    except (subprocess.SubprocessError,ValueError) as error:return {'available':False,'reason':str(error)}


def _mac_snapshot(contract):
    env=clean_env(contract)
    text=subprocess.check_output([contract['gpuSlot'],'--status'],env=env,text=True,timeout=15)
    pressure=subprocess.check_output(['sysctl','-n','kern.memorystatus_vm_pressure_level'],text=True,timeout=10).strip()
    return parse_mac(text,pressure,env)


def parse_mac(text,pressure,env):
    header=re.search(r'memory budget ([0-9.]+) GB',text)
    if not header:raise ValueError('unrecognized gpu-slot status')
    slots=int(env.get('BOMBCAD_GPU_SLOTS',3));normal=pressure=='1'
    free={int(i) for i in re.findall(r'^slot (\d+): free$',text,re.M)}
    occupied=sum(float(x) for x in re.findall(r'^slot \d+:.*\(([0-9.]+) GB\)',text,re.M))
    return {'status':text,'pressure':pressure,'budgetGB':float(header[1]),'declaredGB':occupied,
            'regularFree':bool(free&set(range(1,(slots if normal else min(2,slots))+1))),
            'smallFree':normal and slots+2 in free,'waiting':bool(re.search(r'^waiting:',text,re.M)),'available':True}


PC_PROBE='''import json,os,subprocess
from pathlib import Path
p=Path('bombcad-ml/lock');owner=None;stale=False
if p.exists():
 try:
  owner=json.loads((p/'owner').read_text());boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
  if owner.get('boot') and owner['boot']!=boot:stale=True
  else:
   try:os.kill(int(owner['pid']),0)
   except ProcessLookupError:stale=True
 except Exception:owner={'what':'unknown/starting'}
r=subprocess.run(['nvidia-smi','--query-gpu=index,memory.free,utilization.gpu','--format=csv,noheader,nounits'],capture_output=True,text=True,check=True)
lines=r.stdout.strip().splitlines()
if len(lines)!=1:raise RuntimeError('queue requires explicit single-GPU worker')
i,free,util=map(int,lines[0].split(','))
print(json.dumps(dict(available=(owner is None or stale) and util<=5,owner=owner,staleLock=stale,freeBytes=free*1048576,utilization=util,deviceIndex=i)))
'''


def pc_snapshot(contract):
    if not contract['cuda']:return {'available':False,'reason':'not configured','freeBytes':0}
    try:
        r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',contract['cuda']['host'],
                          'python3 -c '+shlex.quote(PC_PROBE)],capture_output=True,text=True,timeout=20,check=True)
        return json.loads(r.stdout)
    except (subprocess.SubprocessError,ValueError) as error:return {'available':False,'reason':str(error),'stderr':str(getattr(error,'stderr','') or '')[-4096:], 'freeBytes':0}


def plan_dispatch(contract,states,mac,pc,now=None):
    now=time.time() if now is None else now
    active=[a for state in states.values() for a in state.get('active',[])]
    lanes={m:[a for a in active if a['backend']==m] for m in ('metal','cuda')}
    ready={'metal':mac.get('available',False) and not mac.get('waiting',True), 'cuda':pc.get('available',False)}
    ends={m:(max(max(0.,a['estimatedSeconds']-(now-a['startedAt'])) for a in lanes[m]) if lanes[m] else 0. if ready[m] else math.inf) for m in lanes}
    proposals=[]
    for job in contract['jobs']:
        state=states[job['key']]
        if state['status']!='pending' or state['retryAfter']>now:continue
        candidates=[]
        for mode in state['eligibleBackends']:
            if mode=='metal':
                fits=job['metalGB']+mac.get('declaredGB',math.inf)<=mac.get('budgetGB',0)
                fits &= (mac.get('regularFree',False) or (job['metalGB']<=2 and mac.get('smallFree',False)) or bool(lanes['metal']))
                fits &= job['metalGB']<8 or mac.get('pressure')=='1'
            else:
                fits=job['cudaBytes']<=pc.get('freeBytes',0)*.8
                if not state.get('preparationCache'):
                    fits &= job['metalGB']+mac.get('declaredGB',math.inf)<=mac.get('budgetGB',0)
                    fits &= (mac.get('regularFree',False) or (job['metalGB']<=2 and mac.get('smallFree',False)))
                    fits &= job['metalGB']<8 or mac.get('pressure')=='1'
            estimate=job.get('cachedCudaEstimatedSeconds',job['estimatedSeconds'][mode]) if mode=='cuda' and state.get('preparationCache') else job['estimatedSeconds'][mode]
            if fits and math.isfinite(ends[mode]):candidates.append((ends[mode]+estimate,mode,ends[mode],estimate))
        if not candidates:continue
        finish,mode,start,estimate=min(candidates,key=lambda x:(x[0],x[1]!='metal'))
        proposals.append({'case':job['key'],'backend':mode,'estimatedStartSeconds':start,'estimatedFinishSeconds':finish,
                          'estimatedSeconds':estimate,'preparationCache':state.get('preparationCache') if mode=='cuda' else None,
                          'launchNow':start==0 and not lanes[mode] and ready[mode]})
        ends[mode]=finish
    return proposals


def run_command(command,log,contract,deadline):
    remaining=deadline-time.perf_counter()
    if remaining<=0:raise TimeoutError('case execution deadline')
    with Path(log).open('a') as f:
        subprocess.run(command,check=True,stdout=f,stderr=subprocess.STDOUT,env=clean_env(contract),timeout=remaining)


def producer_phases(folder,mode):
    try:report=read(folder/'phase-timings.json')
    except (OSError,ValueError) as error:raise GateFailure('producer phase receipt unavailable') from error
    if not isinstance(report,dict) or report.get('format')!='bombcad-field-phases-1' or report.get('mode')!=mode or not isinstance(report.get('clock'),str):raise GateFailure('producer phase receipt incompatible')
    seconds=report.get('seconds',{})
    names={'scenePreparationSeconds','solverSetupIncludingCompileSeconds','recorderSetupSeconds','solveSeconds','outputSeconds'}
    total=report.get('totalSecondsBeforeTimingReceipt')
    if not isinstance(seconds,dict) or set(seconds)!=names or any(type(v) not in (int,float) or not math.isfinite(v) or v<0 for v in [*seconds.values(),total]):raise GateFailure('producer phase values invalid')
    if sum(seconds.values())>total+1e-5:raise GateFailure('producer phase accounting invalid')
    if 'solverSetupPhasesSeconds' in report:
        phases=report['solverSetupPhasesSeconds']
        expected={'commandQueueSeconds','shaderLibrarySeconds','eagerPipelinesSeconds','buffersAndTextureSeconds','initialUniformStateSeconds','scenarioLoadSeconds'}
        if not isinstance(phases,dict) or set(phases)!=expected or any(type(v) not in (int,float) or not math.isfinite(v) or v<0 for v in phases.values()):raise GateFailure('producer setup phase values invalid')
        if sum(phases.values())>seconds['solverSetupIncludingCompileSeconds']+1e-5:raise GateFailure('producer setup phase accounting invalid')
    return report


def verify_prepared(folder,contract,job):
    item=read(folder/'queue-prepared.json');check=dict(item);key=check.pop('key')
    if address(check)!=key or item['case']!=job['key'] or item['contract']!=contract['key']:raise GateFailure('prepared identity differs')
    for name,expected in item['filesSHA256'].items():
        if Path(name).name!=name or digest(folder/name)!=expected:raise GateFailure('prepared bytes changed')
    return key


def worker(root,key,attempt_id):
    root=Path(root).resolve()
    if not re.fullmatch('[0-9a-f]{32}',attempt_id):raise ValueError('invalid attempt identity')
    contract=read(root/'contract.json');job=next(j for j in contract['jobs'] if j['key']==key)
    folder=root/'cases'/key;attempt=folder/'attempts'/attempt_id;request=read(attempt/'request.json')
    if request['backend'] not in job['backends'] or request['decision']['case']!=key:raise ValueError('unapproved case/backend request')
    if os.getpgrp()!=os.getpid():raise ValueError('case worker requires its own process group')
    birth=process_snapshot(os.getpid())
    atomic(attempt/'process.json',{'pid':os.getpid(),'pgid':os.getpgrp(),'startedAt':time.time(),'boot':boot_id(),
                                  'birth':birth['birth'] if birth else None,'attempt':attempt_id,'queue':str(root)})
    def interrupted(*_):raise InterruptedError('owned case worker interrupted')
    signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
    started=time.perf_counter();deadline=started+job['timeoutSeconds'];mode=request['backend'];timings={}
    with lease(attempt/'active.lock') as active,lease(folder/'case.lock') as owned:
        if active is None:return 0
        if owned is None:
            atomic(attempt/'result.json',{'status':'deferred','error':'case already leased','finishedAt':time.time()});return 0
        try:
            verify_contract(contract)
            if (folder/'accepted.json').exists():
                ident=read(folder/'accepted.json')['object'];object_receipt(root,ident,contract,job)
                atomic(attempt/'result.json',{'status':'reused','object':ident,'finishedAt':time.time()});return 0
            def phase(name):atomic(attempt/'progress.json',{'phase':name,'updatedAt':time.time()})
            if mode=='metal':
                phase('metal');begin=time.perf_counter();result=attempt/'metal-result'
                run_command([contract['gpuSlot'],'--mem',str(job['metalGB']),contract['scenebench'],'field-export',*job['arguments'],'--phase-timings','--out',str(result)],attempt/'backend.log',contract,deadline)
                timings['metalCaseSeconds']=time.perf_counter()-begin
                timings['producer']=producer_phases(result,'metal')
                os.rename(result/'phase-timings.json',attempt/'producer-phases.json')
                provenance={'backend':'metal','executableSHA256':contract['filesSHA256'][contract['scenebench']]}
            else:
                config=contract['cuda'];pc=pc_snapshot(contract)
                if not pc['available']:raise Deferred('PC busy/unreachable before preparation')
                phase('prepare');begin=time.perf_counter();source=attempt/'solver.cu';source.write_text(generate());prepared=folder/'prepared'
                cache_hit=prepared.exists()
                if not cache_hit:
                    fresh=attempt/'input'
                    run_command([contract['gpuSlot'],'--mem',str(job['metalGB']),contract['scenebench'],'field-export',*job['arguments'],'--phase-timings','--cuda-job','--cuda-source',str(source),'--out',str(fresh)],attempt/'backend.log',contract,deadline)
                    try:validate(fresh,source.read_text())
                    except ValueError as error:raise GateFailure('CUDA contract rejected: '+str(error)) from error
                    producer_phases(fresh,'cuda-prepare')
                    cache={'case':key,'contract':contract['key'],'filesSHA256':{f.name:digest(f) for f in fresh.iterdir() if f.is_file()}}
                    cache['key']=address(cache);atomic(fresh/'queue-prepared.json',cache)
                    os.rename(fresh,prepared);sync_directory(folder)
                timings['prepareSeconds']=time.perf_counter()-begin
                timings['preparationCacheHit']=cache_hit
                cache_key=verify_prepared(prepared,contract,job)
                timings['producerPreparation']=producer_phases(prepared,'cuda-prepare')
                try:meta,_=validate(prepared,source.read_text())
                except ValueError as error:raise GateFailure('CUDA contract rejected: '+str(error)) from error
                if arguments(read(prepared/'meta.json')['arguments'],reference=True)!=arguments(job['arguments']):raise GateFailure('exported command differs')
                expected_terrain=job['physics']=='recommended-static-terrain'
                if bool('terrain' in meta)!=expected_terrain:raise GateFailure('exported geometry differs from declaration')
                required=(77 if 'cooling' in meta else 65)*math.prod(meta['shape'])+36*meta['shape'][0]*meta['shape'][1]
                required+=sum((prepared/n).stat().st_size for n in meta['files'] if n.startswith('cut-'))
                if required>job['cudaBytes']:raise GateFailure('CUDA memory declaration below actual exported requirement')
                pc=pc_snapshot(contract)
                if not pc['available'] or required>pc['freeBytes']*.8:raise Deferred('PC busy or memory unavailable after preparation')
                phase('deploy');out=attempt/'cuda-result'
                # Bound SSH/scp calls while retaining their normal provenance/lock protocol.
                original=remote.command
                def controlled(args):
                    if args[0] in ('ssh','scp'):args=[args[0],'-o','ConnectTimeout=10','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=4',*args[1:]]
                    run_command(args,attempt/'backend.log',contract,deadline)
                remote.command=controlled
                try:report=remote.deploy(config['host'],prepared,out,python=config.get('python','bombcad-ml/venv/bin/python'),dataset_only=True,cache_dir=config.get('cacheDir'))
                finally:remote.command=original
                deployment=read(out/'deployment.json');timings['deployment']=deployment['timings'];timings['deploymentTotalSeconds']=deployment['totalSecondsBeforeReceipt']
                timings['compileSecondsWorkerClock']=report['timings']['compileSeconds'];timings['solveSecondsWorkerClock']=report['wallSeconds']
                provenance={'backend':'cuda','result':report,'deployment':deployment,'actualRequiredBytes':required,'preparedObject':cache_key}
                result=out/'dataset'
            phase('compare');begin=time.perf_counter()
            try:
                field_metadata(result,arguments(job['arguments']))
                gate=compare(job['reference'],result)
            except (OSError,ValueError) as error:raise GateFailure('target contract rejected: '+str(error)) from error
            timings['compareSeconds']=time.perf_counter()-begin
            if not gate['passed']:raise GateFailure(json.dumps(gate))
            verify_contract(contract)
            receipt={'contract':contract['key'],'case':key,'id':job['id'],'backend':mode,'provenance':provenance,
                     'comparison':gate,'filesSHA256':{n:digest(result/n) for n in DATA_FILES},
                     'timings':timings,'totalSecondsBeforePublication':time.perf_counter()-started,'attempt':attempt_id}
            ident=address(receipt);publish=attempt/'publish';publish.mkdir();os.rename(result,publish/'dataset')
            for name in DATA_FILES:
                with (publish/'dataset'/name).open('rb+') as f:os.fsync(f.fileno())
            sync_directory(publish/'dataset');atomic(publish/'receipt.json',receipt)
            os.rename(publish,root/'objects'/ident);sync_directory(root/'objects')
            atomic(folder/'accepted.json',{'object':ident});atomic(attempt/'result.json',{'status':'accepted','object':ident,'finishedAt':time.time()})
            phase('accepted');return 0
        except BaseException as error:
            text=(attempt/'backend.log').read_text(errors='replace') if (attempt/'backend.log').exists() else ''
            busy='PC GPU is held by another job; retry after it finishes' in text
            status='blocked' if isinstance(error,GateFailure) else 'deferred' if isinstance(error,Deferred) or busy else 'failed'
            atomic(attempt/'result.json',{'status':status,'error':repr(error),'timings':timings,'totalSeconds':time.perf_counter()-started,'finishedAt':time.time()})
            return 1 if status in ('failed','blocked') else 0


def launch(root,contract,proposal,observations):
    root=Path(root).resolve()
    key=proposal['case'];ident=uuid.uuid4().hex;attempt=root/'cases'/key/'attempts'/ident;attempt.mkdir()
    generation=read(root/'cases'/key/'retry.json')['generation'] if (root/'cases'/key/'retry.json').exists() else 0
    atomic(attempt/'request.json',{'backend':proposal['backend'],'generation':generation,'createdAt':time.time(),'decision':proposal,'observations':observations})
    with (attempt/'worker.log').open('w') as log:
        process=subprocess.Popen([sys.executable,str(HERE/'field-queue.py'),'_worker','--queue',str(root),'--case',key,'--attempt',ident],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    _CHILDREN.append(process)
    birth=process_snapshot(process.pid)
    atomic(attempt/'launch.json',{'pid':process.pid,'pgid':process.pid,'boot':boot_id(),
                                 'birth':birth['birth'] if birth else None,'attempt':ident,'queue':str(root)})
    return process


def snapshot_states(root,contract):return {j['key']:case_state(root,contract,j) for j in contract['jobs']}


def run_queue(root,once=False,poll=2,max_seconds=600):
    root=Path(root).resolve()
    contract=read(root/'contract.json');verify_contract(contract)
    with lease(root/'controller.lock') as owned:
        if owned is None:raise ValueError('queue already has a controller')
        started=time.perf_counter();previous=None
        try:
            recover(root,contract)
            while True:
                verify_contract(contract);recover(root,contract);states=snapshot_states(root,contract)
                atomic(root/'state.json',{'contract':contract['key'],'updatedAt':time.time(),'cases':states})
                summary={j['id']:states[j['key']]['status'] for j in contract['jobs']}
                if summary!=previous:print(json.dumps(summary),flush=True);previous=summary
                if all(s['status']=='accepted' for s in states.values()):return 0
                if all(s['status'] in ('accepted','failed') for s in states.values()):return 1
                runnable=[j for j in contract['jobs'] if states[j['key']]['status']=='pending'
                          and states[j['key']]['retryAfter']<=time.time()]
                if runnable:
                    needs_mac=any('metal' in states[j['key']]['eligibleBackends'] or not states[j['key']].get('preparationCache') for j in runnable)
                    mac=mac_snapshot(contract) if needs_mac else {'available':False,'reason':'validated CUDA preparation needs no Mac GPU slot'}
                    needs_pc=any('cuda' in states[j['key']]['eligibleBackends'] for j in runnable)
                    pc=pc_snapshot(contract) if needs_pc else {'available':False,'reason':'no runnable CUDA cases','freeBytes':0}
                    proposals=plan_dispatch(contract,states,mac,pc)
                    atomic(root/'dispatch.json',{'observedAt':time.time(),'mac':mac,'cuda':pc,'proposals':proposals})
                    for proposal in proposals:
                        if proposal['launchNow']:launch(root,contract,proposal,{'mac':mac,'cuda':pc})
                _CHILDREN[:]=[p for p in _CHILDREN if p.poll() is None] # Retain live handles across run-once calls.
                if once or time.perf_counter()-started>=max_seconds:return 75
                time.sleep(poll)
        except KeyboardInterrupt:
            print('Controller stopped; active case workers continue. Resume this queue to observe them.',flush=True)
            return 130


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('command',choices=('init','run','status','retry','_worker'))
    p.add_argument('--plan',type=Path);p.add_argument('--queue',type=Path,required=True)
    p.add_argument('--once',action='store_true');p.add_argument('--poll',type=float,default=2);p.add_argument('--max-seconds',type=float,default=600)
    p.add_argument('--case');p.add_argument('--attempt');a=p.parse_args();root=a.queue.resolve()
    if a.command=='init':
        if not a.plan:p.error('--plan required')
        contract=init(read(a.plan),root);print(contract['key']);return 0
    if a.command=='_worker':return worker(root,a.case,a.attempt)
    contract=read(root/'contract.json');verify_contract(contract)
    if a.command=='status':
        print(json.dumps({'contract':contract['key'],'cases':snapshot_states(root,contract),
                          'latestDispatch':read(root/'dispatch.json') if (root/'dispatch.json').exists() else None},indent=2));return 0
    if a.command=='retry':
        with lease(root/'controller.lock') as owned:
            if owned is None:raise ValueError('controller active')
            for job in contract['jobs']:
                state=case_state(root,contract,job)
                if state['status']=='failed':
                    path=root/'cases'/job['key']/'retry.json';generation=read(path)['generation'] if path.exists() else 0
                    atomic(path,{'since':time.time(),'generation':generation+1})
        return 0
    if not .1<=a.poll<=60 or not 1<=a.max_seconds<=86400:p.error('invalid polling/deadline bounds')
    return run_queue(root,a.once,a.poll,a.max_seconds)


if __name__=='__main__':sys.exit(main())
