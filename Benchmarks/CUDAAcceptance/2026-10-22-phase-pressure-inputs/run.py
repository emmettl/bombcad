"""Read-only CUDA pressure-input diagnostics on three corrected physical jobs."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
BASE=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')
ROOT=BASE.parent/'2026-10-22-phase-pressure-inputs'


def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def load(p):return json.loads(Path(p).read_text())
def save(p,v):
    t=Path(str(p)+'.tmp');t.write_text(json.dumps(v,indent=2)+'\n');os.replace(t,p)
def module(n,p):
    s=importlib.util.spec_from_file_location(n,p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m


def main():
    ROOT.mkdir(exist_ok=False);(ROOT/'analysis').mkdir();(ROOT/'cases').mkdir()
    for n in ['run.py','build_worker.py','pressure_model.py','check_model.py','plan.md']:shutil.copyfile(HERE/n,ROOT/'analysis'/n)
    build=module('builder',ROOT/'analysis/build_worker.py');worker=ROOT/'worker';worker_pins=build.build(BASE,worker)
    frozen=load(BASE/'run.json');assert worker_pins['solver.cu']==frozen['generatedSourceSHA256']
    source=(worker/'solver.cu').read_text()
    for token in ['287.05f','3390.0f, 2270.0f','0.79f, 0.21f','3.3791424f','20.550920f','137.42716f','249.79498f','3.3600479f','21.645931f','118.98650f','349.70334f']:
        assert token in source,token
    pins={str(p):sha(p) for folder in ['analysis','worker'] for p in (ROOT/folder).iterdir() if p.is_file()}
    inventory=load(BASE/'recovery/remote-inventory.json')
    cases=[dict(id='made-perimeter-s1-1',columns=[62902]),dict(id='made-perimeter-s3-1',columns=[134058,250097]),dict(id='beirut-p0-1',columns=[187747])]
    state=dict(status='controls',controllerPID=os.getpid(),workerSHA256=worker_pins,pins=pins,rows=[],cases=cases,commands=[])
    def checkpoint():save(ROOT/'run.json',state)
    def verify():
        for p,h in pins.items():assert sha(p)==h,p
    def command(args,label,log):
        verify()
        with Path(log).open('wb') as f:
            p=subprocess.Popen(args,cwd=REPO,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            entry=dict(label=label,pid=p.pid,command=args);state['liveProcess']=entry;checkpoint();code=p.wait()
        state.pop('liveProcess');entry['returncode']=code;state['commands'].append(entry);checkpoint();verify();return code
    checkpoint()
    try:
        assert command([sys.executable,'-B',str(ROOT/'analysis/check_model.py')],'math-controls',ROOT/'math-controls.log')==0
        state['status']='running';checkpoint()
        for case in cases:
            name=case['id'];folder=ROOT/'cases'/name;folder.mkdir();baseline=inventory[name+'/current']['remote']
            job=load(BASE/'cases'/name/'input/job.json');assert job['uniforms']['airModel']==1
            for n,h in job['files'].items():assert sha(BASE/'cases'/name/'input'/n)==h
            remote='bombcad-cuda/'+worker_pins['solver.cu'][:16]+'/jobs/'+uuid.uuid4().hex
            row=dict(id=name,status='deploying',columns=case['columns'],baselineRemote=baseline,remote=remote);state['rows'].append(row);checkpoint()
            try:
                text="from pathlib import Path;p=Path.home()/"+repr(remote)+";p.mkdir(parents=True,exist_ok=False)"
                subprocess.run(['ssh','-o','BatchMode=yes','bombcad-pc','python3 -c '+shlex.quote(text)],check=True)
                subprocess.run(['scp','-q','-r',str(worker),'bombcad-pc:'+remote+'/worker'],check=True)
                config=dict(remote=remote,baseline=baseline,columns=case['columns'],worker=worker_pins)
                remote_script='''import hashlib,json,os,pathlib,signal,subprocess
c=CONFIG;root=pathlib.Path.home();remote=root/c['remote'];base=root/c['baseline']
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
for n,h in c['worker'].items():assert digest(remote/'worker'/n)==h
j=json.loads((base/'input/job.json').read_text());assert j['sourceSHA256']==c['worker']['solver.cu']
for n,h in j['files'].items():assert digest(base/'input'/n)==h
args=[str(root/'bombcad-ml/venv/bin/python'),str(remote/'worker/run.py'),str(base/'input'),'--source',str(remote/'worker/solver.cu'),'--out',str(remote/'out'),'--trace-columns',','.join(map(str,c['columns'])),'--lock',str(root/'bombcad-ml/lock'),'--cache-dir',str(root/'bombcad-cuda/ptx-cache')]
p=subprocess.Popen(args,start_new_session=True);boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip();birth=pathlib.Path(f'/proc/{p.pid}/stat').read_text().split()[21]
receipt=dict(pid=p.pid,boot=boot,birthTicks=birth,command=args)
(remote/'controller.json').write_text(json.dumps(receipt,indent=2)+'\\n')
try:code=p.wait(timeout=4800)
except subprocess.TimeoutExpired:
 assert pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()==boot and pathlib.Path(f'/proc/{p.pid}/stat').read_text().split()[21]==birth
 os.killpg(p.pid,signal.SIGTERM)
 try:code=p.wait(timeout=10)
 except subprocess.TimeoutExpired:
  assert pathlib.Path(f'/proc/{p.pid}/stat').read_text().split()[21]==birth
  os.killpg(p.pid,signal.SIGKILL);code=p.wait()
 receipt['timedOut']=True
receipt.update(returncode=code,status='terminal');(remote/'controller.json').write_text(json.dumps(receipt,indent=2)+'\\n')
raise SystemExit(code)
'''.replace('CONFIG',repr(config))
                code=command(['ssh','-o','BatchMode=yes','bombcad-pc','python3 -c '+shlex.quote(remote_script)],name,folder/'worker.log')
                row['returncode']=code;checkpoint()
                subprocess.run(['scp','-q','bombcad-pc:'+remote+'/controller.json',str(folder/'remote-controller.json')],check=True)
                if code:row['status']='worker-failed';checkpoint();continue
                for n in ['trace.npy','trace.json','pressure-inputs.npy','pressure-inputs.json','result.json']:
                    subprocess.run(['scp','-q','bombcad-pc:'+remote+'/out/'+n,str(folder/n)],check=True)
                result=load(folder/'result.json');assert result['sourceSHA256']==worker_pins['solver.cu']
                assert result['workerFilesSHA256']=={n:worker_pins[n] for n in ['run.py','job.py','compile.py','trace_columns.py']}
                old_trace=module('new_trace_'+str(len(state['rows'])),worker/'trace_columns.py')
                expected=hashlib.sha256((source+old_trace.trace_source(source)+old_trace.input_source()).encode()).hexdigest()
                assert result['diagnosticSourceSHA256']==expected and result['traceColumns']==case['columns']
                proof_script='''import hashlib,json,pathlib,numpy as np
root=pathlib.Path.home();old=root/OLD;new=root/NEW
def files(p):
 def digest(f):
  h=hashlib.sha256()
  with f.open('rb') as s:
   for b in iter(lambda:s.read(1048576),b''):h.update(b)
  return dict(bytes=f.stat().st_size,sha256=h.hexdigest())
 return {str(f.relative_to(p)):digest(f) for f in sorted(p.rglob('*')) if f.is_file() and f.suffix in ('.bin','.npy')}
a=files(old/'out');b=files(new/'out');assert a and all(b.get(k)==v for k,v in a.items());assert set(b)-set(a)=={'trace.npy','pressure-inputs.npy'}
j=json.loads((old/'input/job.json').read_text());nx,ny,nz=j['shape'];plane=nx*ny
columns=np.memmap(old/'input/columns.bin',mode='r',dtype='<u4').reshape(-1,4)
initial=np.memmap(old/'input/state.bin',mode='r',dtype='<u4').reshape(-1,5);final=np.memmap(new/'out/state.bin',mode='r',dtype='<u4').reshape(-1,5)
records=np.memmap(old/'input/records.bin',mode='r',dtype='<u4').reshape(-1,4);opened=np.memmap(old/'input/open.bin',mode='r',dtype='<u4')
endpoints=[]
for n in COLUMNS:
 cv=columns[n].view(np.float32);indices=[n+plane*int(cv[0]),n+plane*int(cv[1])]
 endpoints.append(dict(column=n,columnWords=columns[n].tolist(),indices=indices,initialCellWords=initial[indices].tolist(),finalCellWords=final[indices].tolist(),initialRecordWords=records[n].tolist(),initialOpenWord=int(opened[n])))
print(json.dumps(dict(baseline=a,traced=b,endpoints=endpoints,uniforms=j['uniforms'],shape=j['shape'])))
'''.replace('OLD',repr(baseline)).replace('NEW',repr(remote)).replace('COLUMNS',repr(case['columns']))
                proof=json.loads(subprocess.check_output(['ssh','-o','BatchMode=yes','bombcad-pc','bombcad-ml/venv/bin/python -c '+shlex.quote(proof_script)],text=True))
                original=inventory[name+'/current']['files']
                for n,v in proof['baseline'].items():assert original['out/'+n]==v
                for n in ['trace.npy','pressure-inputs.npy']:assert sha(folder/n)==proof['traced'][n]['sha256']
                save(folder/'parity-and-endpoints.json',proof)
                row.update(status='captured-parity-pass',allOriginalNumericAndDtBytesEqual=True,extraNumericFiles=['trace.npy','pressure-inputs.npy']);checkpoint()
            except Exception as error:row.update(status='failed',error=repr(error));checkpoint()
        verify();state.update(status='complete-all-outcomes',allThreeCaptured=all(r['status']=='captured-parity-pass' for r in state['rows']) and len(state['rows'])==3);checkpoint()
        print(json.dumps({k:v for k,v in state.items() if k not in ['pins']},indent=2))
    except BaseException as error:state.update(status='failed',error=repr(error));checkpoint();raise


if __name__=='__main__':main()
