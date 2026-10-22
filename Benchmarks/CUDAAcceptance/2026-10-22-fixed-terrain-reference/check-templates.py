"""Validate future template attachment on copies of all three real physical jobs; CPU only."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

HERE=Path(__file__).resolve().parent
ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-fixed-terrain-reference')

def module(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def main(out):
    out=Path(out);out.mkdir(exist_ok=False);runner=module('future_pilot',HERE/'run-pilots.py');validator=module('frozen_job_validator',ROOT/'analysis/cuda/job.py');source=(ROOT/'solver.cu').read_text();controls=[]
    for job in json.loads((ROOT/'run.json').read_text())['jobs']:
        name=job['id'];original=ROOT/'cases'/name/'input';ref=ROOT/'cases'/name/'metal';dest=out/name;dest.mkdir()
        before=json.loads((original/'job.json').read_text());shutil.copyfile(original/'job.json',dest/'job.json')
        # Same-volume read-only buffer aliases; only the copied descriptor/templates are written.
        for file in before['files']:os.link(original/file,dest/file)
        validator.validate(dest,source);runner.attach_dataset_templates(dest,ref);after,_=validator.validate(dest,source)
        assert {k:v for k,v in after.items() if k!='dataset'}==before
        assert set(after['dataset'])=={'inputs.npy','mask.npy','meta.json'}
        assert all(runner.sha(original/file)==pin for file,pin in before['files'].items())
        for file in ['inputs.npy','mask.npy']:assert runner.sha(dest/file)==runner.sha(ref/file)
        details=json.loads((dest/'meta.json').read_text());assert details['stable'] is False and details['configuration']=='recommended; awaiting CUDA'
        controls.append(dict(id=name,physicalJobFieldsAndBuffersUnchanged=True,frozenCPUValidatorPassedBeforeAndAfter=True,featureMaskBytesUnchanged=True,uncomputedTemplateMarkedUnstable=True))
    bad=out/'bad';bad.mkdir();reference=out/'bad-reference';reference.mkdir();base=ROOT/'cases'/job['id'];shutil.copyfile(base/'input/job.json',bad/'job.json');original_bytes=(bad/'job.json').read_bytes();meta=json.loads((base/'metal/meta.json').read_text());meta['stable']=False;(reference/'meta.json').write_text(json.dumps(meta))
    try:runner.attach_dataset_templates(bad,reference);raise AssertionError('unstable template accepted')
    except ValueError as e:assert str(e)=='stable three-channel reference required'
    assert (bad/'job.json').read_bytes()==original_bytes and sorted(p.name for p in bad.iterdir())==['job.json']
    result=dict(status='pass',scope='CPU packaging preflight on copies; no Metal/CUDA solver run. Physical buffers aliased read-only and independently rehashed.',controls=controls,unstableReferenceRefusedBeforeWrites=True,runnerSHA256=runner.sha(HERE/'run-pilots.py'),validatorSHA256=runner.sha(ROOT/'analysis/cuda/job.py'))
    (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

if __name__=='__main__':main(sys.argv[1])
