"""Query actual loaded kernel limits and explicitly prime both precise PTX variants before timing."""
from pathlib import Path
import importlib.util,json,ctypes as C,hashlib
root=Path(__file__).resolve().parent

def module(file,name):
 spec=importlib.util.spec_from_file_location(name,root/file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
lock=module('remote-train.py','lock');path=str(Path.home()/'bombcad-ml/lock')
if not lock.acquire(path,'launch-block limits/cache preflight',lock.boot_id()):raise SystemExit('GPU held')
try:
 import torch
 torch.cuda.init();anchor=torch.empty(1,device='cuda');driver=C.CDLL('libcuda.so.1')
 def check(code):
  if code:raise RuntimeError('CUDA driver error '+str(code))
 compiler=module('compile.py','compiler');source=(root/'solver.cu').read_text();cap=torch.cuda.get_device_capability();rows=[]
 names=['cudaSweep','cudaPrepare','cudaMeasure','cudaFirstPhase','cudaCoolingClock','cudaCoolingReset','cudaCoolingMedium','cudaCoolingLines','cudaCoolingApply','cudaRedistribute']
 for terrain in [False,True]:
  ptx=compiler.compile_ptx(source,f'compute_{cap[0]}{cap[1]}',cut_cells=terrain,cache_dir=Path.home()/'bombcad-cuda/ptx-cache');mod=C.c_void_p();check(driver.cuModuleLoadData(C.byref(mod),ptx))
  try:
   for name in names:
    fun=C.c_void_p();check(driver.cuModuleGetFunction(C.byref(fun),mod,name.encode()));attributes={}
    for number,key in [(0,'maxThreadsPerBlock'),(1,'sharedBytesPerBlock'),(3,'localBytesPerThread'),(4,'registersPerThread')]:
     value=C.c_int();check(driver.cuFuncGetAttribute(C.byref(value),number,fun));attributes[key]=value.value
    assert attributes['maxThreadsPerBlock']>=256,(name,attributes);rows.append(dict(cutCells=terrain,kernel=name,**attributes))
  finally:check(driver.cuModuleUnload(mod))
 result=dict(status='complete',device=torch.cuda.get_device_name(),torch=torch.__version__,cuda=torch.version.cuda,sourceSHA256=hashlib.sha256(source.encode()).hexdigest(),sizes=[64,128,256],precisePTXPrimedBeforeTiming=True,kernels=rows)
 (root/'preflight.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
finally:lock.release(path)
