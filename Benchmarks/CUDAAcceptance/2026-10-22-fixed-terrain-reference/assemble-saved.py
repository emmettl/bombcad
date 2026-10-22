"""Recover missing dataset packaging from immutable saved CUDA arrays; no solver execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import numpy as np

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')
HERE=Path(__file__).resolve().parent

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for b in iter(lambda:stream.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def save(path,data):path.write_text(json.dumps(data,indent=2)+'\n')

def main():
    root=ROOT/'recovery';inventory=json.loads((root/'remote-inventory.json').read_text());jobs=json.loads((root/'jobs.json').read_text());frozen=json.loads((ROOT/'run.json').read_text())
    assert {j['id'] for j in jobs}=={j['id'] for j in frozen['jobs']}
    (root/'analysis').mkdir(exist_ok=False);shutil.copyfile(__file__,root/'analysis/assemble-saved.py')
    state=dict(status='retrieving',scope='Saved-output packaging only; no Metal/CUDA/oracle rerun. Original retrieval failure retained.',controls=[],rows=[],sourceSHA256=sha(__file__),pythonVersion=sys.version,numpyVersion=np.__version__)
    save(root/'run.json',state)
    def fetch(name,kind,relative):
        item=inventory[name+'/'+kind];pin=item['files'][relative];dest=root/kind/name/relative;dest.parent.mkdir(parents=True,exist_ok=True)
        if not dest.exists():subprocess.run(['scp','-q','bombcad-pc:'+item['remote']+'/'+relative,str(dest)],check=True)
        assert dest.stat().st_size==pin['bytes'] and sha(dest)==pin['sha256']
        return dest
    def assemble(raw,mask):
        target=np.load(raw/'targets.npy',allow_pickle=False);phase=np.load(raw/'firstPhaseImpulse.npy',allow_pickle=False)
        assert target.dtype==phase.dtype==np.dtype('<f4') and target.shape==(2,*mask.shape) and phase.shape==mask.shape
        full=np.stack([target[0],target[1],phase]).astype('<f4');full[:,mask==0]=0
        assert np.isfinite(full[:,mask!=0]).all()
        return full
    try:
        for j in jobs:
            name=j['id']
            for kind in ['current','control']:
                for n in ['targets.npy','firstPhaseImpulse.npy','mask.npy','dt.npy','result.json']:fetch(name,kind,'out/'+n)
                for n in ['job.json','columns.bin']:fetch(name,kind,'input/'+n)
            for n in ['inputs.npy','mask.npy','meta.json']:fetch(name,'control','input/'+n)
            for n in ['inputs.npy','mask.npy','targets.npy','meta.json']:fetch(name,'control','out/dataset/'+n)
        # Validate all original normal-worker datasets before comparing any current target.
        for j in jobs:
            name=j['id'];control=root/'control'/name;template=control/'input';actual=control/'out/dataset'
            mask=np.load(template/'mask.npy',allow_pickle=False);assembled=assemble(control/'out',mask);expected=np.load(actual/'targets.npy',allow_pickle=False)
            assert expected.dtype==assembled.dtype and np.array_equal(assembled.view(np.uint32),expected.view(np.uint32))
            for n in ['inputs.npy','mask.npy']:
                assert sha(template/n)==sha(actual/n)==sha(ROOT/'cases'/name/'metal'/n)
            current=root/'current'/name
            assert sha(current/'input/columns.bin')==sha(ROOT/'cases'/name/'input/columns.bin')==sha(template/'columns.bin')
            old_meta=json.loads((template/'meta.json').read_text());new_meta=json.loads((ROOT/'cases'/name/'metal/meta.json').read_text())
            for key in ['id','rows','columns','cellSizeM','charge','targets']:assert old_meta[key]==new_meta[key],key
            native_mask=np.load(current/'out/mask.npy',allow_pickle=False);assert native_mask.shape==mask.shape and np.all(native_mask[mask!=0]!=0)
            state['controls'].append(dict(id=name,wholeControlTargetWordEquality=True,unchangedTemplateFeatureMaskBytes=True,unchangedReceiverColumnBytes=True,allSelectedPixelsNativeValid=True))
        state['status']='controls-pass';save(root/'run.json',state)
        spec=importlib.util.spec_from_file_location('frozen_comparison',ROOT/'analysis/cuda/compare_dataset.py');compare=importlib.util.module_from_spec(spec);spec.loader.exec_module(compare)
        assert sha(ROOT/'analysis/cuda/compare_dataset.py')==frozen['frozenFiles']['analysis/cuda/compare_dataset.py']['sha256']
        for j in jobs:
            name=j['id'];current=root/'current'/name;template=root/'control'/name/'input';dataset=current/'dataset';dataset.mkdir(exist_ok=False)
            report=json.loads((current/'out/result.json').read_text());assert report['sourceSHA256']==frozen['generatedSourceSHA256']
            expected={n:frozen['frozenFiles']['analysis/cuda/'+n]['sha256'] for n in ['run.py','job.py','compile.py']};assert report['workerFilesSHA256']==expected
            assert report['startTime']==json.loads((ROOT/'cases'/name/'input/initial-diagnostic.json').read_text())['time']
            mask=np.load(template/'mask.npy',allow_pickle=False);np.save(dataset/'targets.npy',assemble(current/'out',mask))
            for n in ['inputs.npy','mask.npy']:shutil.copyfile(template/n,dataset/n)
            details=json.loads((ROOT/'cases'/name/'metal/meta.json').read_text());details.update(stable=True,steps=report['steps'],untilS=report['startTime']+report['elapsedSimulationTime'],wallS=report['wallSeconds'],cudaProvenance=report)
            details['configuration']+='; CUDA uniform; saved-output dataset assembly'
            details['postprocessing']=dict(type='saved-output-dataset-assembly-1',rawFilesSHA256={n:sha(current/'out'/n) for n in ['targets.npy','firstPhaseImpulse.npy','mask.npy','dt.npy','result.json']},templateFilesSHA256={n:sha(template/n) for n in ['inputs.npy','mask.npy','meta.json','columns.bin']},assemblySourceSHA256=sha(__file__),controls=state['controls'])
            save(dataset/'meta.json',details);shutil.copyfile(current/'out/result.json',current/'result.json')
            comparison=compare.compare(ROOT/'cases'/name/'metal',dataset)
            state['rows'].append(dict(id=name,status='compared',eligible=comparison['passed'],comparison=comparison,datasetDirectory=str(dataset.relative_to(ROOT))))
            save(root/'run.json',state)
        # Recheck all transferred inputs; assembled datasets are separately recorded outputs.
        for key,item in inventory.items():
            name,kind=key.split('/')
            for rel,pin in item['files'].items():
                p=root/kind/name/rel
                if p.exists():assert sha(p)==pin['sha256']
        state['status']='complete-all-outcomes';state['allPilotsPass']=all(r['eligible'] for r in state['rows']) and len(state['rows'])==3;save(root/'run.json',state)
        print(json.dumps(dict(status=state['status'],controls=state['controls'],rows=state['rows']),indent=2))
    except BaseException as error:
        state['status']='failed';state['error']=repr(error);save(root/'run.json',state);raise

if __name__=='__main__':main()
