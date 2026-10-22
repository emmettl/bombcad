"""Hand-calculated gate boundaries for the pilot auditor; no numerical producer."""
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import sys

HERE=Path(__file__).resolve().parent

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def npy(path,shape,values):
    header=repr(dict(descr='<f4',fortran_order=False,shape=shape)).encode();header+=b' '*((-10-len(header)-1)%16)+b'\n'
    path.write_bytes(b'\x93NUMPY\x01\x00'+struct.pack('<H',len(header))+header+struct.pack('<'+'f'*len(values),*values))

def save(path,value):path.write_text(json.dumps(value)+'\n')

def main(root):
    root=Path(root);root.mkdir(exist_ok=False);(root/'analysis/cuda').mkdir(parents=True);(root/'queued-cuda').mkdir()
    comparator=HERE.parents[2]/'Scripts/cuda/compare_dataset.py';shutil.copyfile(comparator,root/'analysis/cuda/compare_dataset.py')
    auditor=module('target_auditor',HERE/'audit-targets.py')
    ids=['made-perimeter-s1-1','made-perimeter-s3-1','beirut-p0-1'];rows=[]
    worker={n:'synthetic-byte-pin' for n in ['run.py','job.py','compile.py']}
    producer=dict(generatedSourceSHA256='synthetic-source-pin',jobs=[dict(id=n) for n in ids],
        frozenFiles={'analysis/cuda/compare_dataset.py':dict(sha256=auditor.sha(comparator))}|{'analysis/cuda/'+n:dict(sha256=v) for n,v in worker.items()})
    save(root/'run.json',producer)
    compare=module('actual_compare',comparator)
    for name in ids:
        ref=root/'cases'/name/'metal';ref.mkdir(parents=True);candidate=root/'queued-cuda'/name/'dataset';candidate.mkdir(parents=True)
        # At 100 Pa, .25 is exactly allowed and the next Float32 value fails.
        # Float32(.05) is slightly above the absolute .05 threshold, so also fails.
        # The huge fifth error is masked; negative reference uses abs(reference).
        x=[100.,100.,-100.,0.,0.,0.];y=[100.25,100.25000762939453,-99.75,.05,1e9,.03125]
        for folder,values in [(ref,x),(candidate,y)]:
            npy(folder/'targets.npy',(3,2,3),values*3);npy(folder/'mask.npy',(2,3),[1,1,1,1,0,1]);npy(folder/'inputs.npy',(6,2,3),[0]*36);save(folder/'meta.json',{})
        source=root/'cases'/name/'input';source.mkdir();save(source/'initial-diagnostic.json',dict(scope='synthetic'))
        save(candidate.parent/'result.json',dict(sourceSHA256='synthetic-source-pin',workerFilesSHA256=worker))
        rows.append(dict(id=name,status='compared',comparison=compare.compare(ref,candidate)))
    save(root/'queued-cuda/run.json',dict(status='complete-all-outcomes',rows=rows))
    auditor.main(root,root/'boundary-results.json');report=json.loads((root/'boundary-results.json').read_text())
    assert report['allThreePilotsPass'] is False
    for row in report['rows']:
        assert row['failureCountsByChannel']==[2,2,2]
        assert len(row['allPerValueFailures'])==6
        assert [(f['channel'],f['index']) for f in row['allPerValueFailures']]==[(c,i) for c in range(3) for i in [1,3]]
    # Exact feature mismatch must refuse rather than score targets or silently mask it.
    folder=root/'queued-cuda'/ids[0]/'dataset';npy(folder/'inputs.npy',(6,2,3),[1]+[0]*35)
    refused=False
    try:auditor.main(root,root/'must-not-exist.json')
    except ValueError as error:assert str(error)=='input features changed';refused=True
    assert refused and not (root/'must-not-exist.json').exists()
    result=dict(status='pass',scope='Synthetic hand-calculated audit controls, not CUDA/Metal numerical evidence',
        expectedFailuresPerCaseAndChannel=[2,2,2],allFailedIndicesRetained=True,exactFeatureMismatchRefused=True,
        auditorSHA256=auditor.sha(HERE/'audit-targets.py'),comparatorSHA256=auditor.sha(comparator))
    save(root/'controls.json',result);print(json.dumps(result,indent=2))

if __name__=='__main__':main(sys.argv[1])
