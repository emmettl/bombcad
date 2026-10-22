"""Only append raw read-only pressure inputs to the frozen diagnostic worker."""
import ast
import hashlib
import json
from pathlib import Path
import shutil
import sys

FIELDS=['column.lo','column.hi','column.fraction','column.valid','weight.lo','weight.hi']+[side+'.'+field for side in ['lo','hi'] for field in ['rho','mx','my','mz','energy']]
KERNEL='''
extern "C" __global__ void cudaTracePressureInputs(const Cell *state,
    const float4 *columns,const SolverUniforms *uniforms,const uint *indices,float *output) {
    uint q=blockIdx.x*blockDim.x+threadIdx.x;
    if(q>=indices[0]) return;
    const SolverUniforms &u=*uniforms;
    uint n=indices[q+1];float4 column=columns[n];
    output[q*16+0]=column.x;output[q*16+1]=column.y;
    output[q*16+2]=column.z;output[q*16+3]=column.w;
    output[q*16+4]=1.0f-column.z;output[q*16+5]=column.z;
    for(uint side=0;side<2;++side) {
        uint k=uint(side==0 ? column.x : column.y);
        Cell c=state[n+u.nx*u.ny*k];uint at=q*16+6+side*5;
        output[at+0]=c.rho;output[at+1]=c.mx;output[at+2]=c.my;
        output[at+3]=c.mz;output[at+4]=c.energy;
    }
}
'''


def build(base,out):
    base=Path(base);out=Path(out);out.mkdir(exist_ok=False)
    for n in ['job.py','compile.py','trace_columns.py','run.py']:shutil.copyfile(base/'analysis/cuda'/n,out/n)
    shutil.copyfile(base/'analysis/ml/remote-train.py',out/'remote-train.py');shutil.copyfile(base/'solver.cu',out/'solver.cu')
    p=out/'trace_columns.py';p.write_text(p.read_text()+'\nINPUT_FIELDS='+repr(FIELDS)+'\n\ndef input_source():\n    return '+repr(KERNEL)+'\n')
    text=(out/'run.py').read_text()
    def replace(a,b):
        nonlocal text
        assert text.count(a)==1,a;text=text.replace(a,b)
    replace('from trace_columns import trace_source, FIELDS','from trace_columns import trace_source, FIELDS, input_source, INPUT_FIELDS')
    replace('compilation_source+=trace_source(source)','compilation_source+=trace_source(source)+input_source()')
    anchor="f=C.c_void_p();check(driver.cuModuleGetFunction(C.byref(f),module,b'cudaTraceColumns'));functions['cudaTraceColumns']=f"
    replace(anchor,anchor+"\n        f=C.c_void_p();check(driver.cuModuleGetFunction(C.byref(f),module,b'cudaTracePressureInputs'));functions['cudaTracePressureInputs']=f")
    replace('trace_rows=[];trace_times=[]','trace_rows=[];trace_times=[]\n        input_values=torch.zeros((len(trace_columns),16),device=\'cuda\',dtype=torch.float32);input_rows=[]')
    replace('trace_rows.append(trace_values.cpu().numpy().copy())',"trace_rows.append(trace_values.cpu().numpy().copy())\n            launch('cudaTracePressureInputs',[state,columns,uniforms,trace_indices,input_values],len(trace_columns))\n            input_rows.append(input_values.cpu().numpy().copy())")
    replace("np.save(out/'trace.npy',np.stack(trace_rows))","np.save(out/'trace.npy',np.stack(trace_rows))\n        np.save(out/'pressure-inputs.npy',np.stack(input_rows))\n        (out/'pressure-inputs.json').write_text(json.dumps({'fields':INPUT_FIELDS,'columns':trace_columns,'scope':'readonly physical cells and native interpolation weights after first-phase recording; no state/record writes'},indent=2)+'\\n')")
    ast.parse(text);(out/'run.py').write_text(text)
    return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}


if __name__=='__main__':print(json.dumps(build(*sys.argv[1:]),indent=2))
