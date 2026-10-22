"""Freeze actual native scalar inputs and complete original producer units; no GPU work."""
import hashlib
import json
from pathlib import Path
import re
import shutil

import numpy as np

HERE=Path(__file__).resolve().parent
ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-clock-selector-replay')
CAP=ROOT.parent/'2026-10-22-clock-inputs'


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def load(path):return json.loads(Path(path).read_text())


def save(path,value):Path(path).write_text(json.dumps(value,indent=2)+'\n')


def main():
    ROOT.mkdir(exist_ok=False)
    for name in ['analysis','runtime','worker','banks']:(ROOT/name).mkdir()
    archive=load(HERE.parent/CAP.name/'archive.json')['manifest']
    consumed={}
    def pin(path):
        assert sha(path)==archive[str(path.relative_to(CAP))]['sha256'],path
        consumed[str(path)]=sha(path)
        return path
    audit=load(pin(CAP/'capture-audit.json'))
    assert audit['allSixOwnBackendCaptureGatesPass']
    assert load(pin(CAP/'remote-verification.json'))['status']=='verified'
    capture=load(pin(CAP/'metal-capture.json'))
    maker=pin(next(Path(s['snapshot']) for s in capture['snapshots'] if s['original'].endswith('/StructureTypes+GPU.swift')))
    text=maker.read_text()
    names=re.findall(r'"([^"]+)"',re.search(r'let files = \[(.*?)\]',text,re.S).group(1))
    assert 'return try device.makeLibrary(source: source, options: nil)' in text
    shader=CAP/'runtime-metal/BombCAD_BlastCore.bundle/Contents/Resources/Shaders'
    prefix=pin(CAP/'runtime-metal/ContinuumKit_ContactSearchMetal.bundle/Contents/Resources/Shaders/ContactSearchFunctions.metal')
    fragments=[pin(shader/(n+'.metal')) for n in names]
    source=prefix.read_text()+'\n'+'\n'.join(p.read_text() for p in fragments)
    assert 'sampleFirstPhasePressure' not in source
    (ROOT/'analysis/producer-main.metal').write_text(source)
    shutil.copyfile(maker,ROOT/'analysis/producer-maker.swift')
    for name in ['solver.cu','compile.py','trace_columns.py','remote-train.py','job.py']:
        shutil.copyfile(pin(CAP/'cuda-worker'/name),ROOT/'worker'/name)
    rows=[]
    for item in audit['rows']:
        backend,name=item['backend'],item['id']
        bank=CAP/('metal' if backend=='metal' else 'capture')/name
        meta=load(pin(bank/'clock-inputs.json'))
        data=np.fromfile(pin(bank/'clock-inputs.bin'),dtype='<u4').reshape(-1,119)
        schema=audit['schemas'][backend]
        c,u=schema['controlWords'],schema['uniformWords'];assert (c,u)==(18,69)
        uniforms=data[:,24:93]
        for key in ['gaugeCount','gravity','forcedStep']:
            assert np.all(uniforms[:,schema['uniformFields'][key]]==0),key
        folder=ROOT/'banks'/(name+'-'+backend);folder.mkdir()
        arrays=dict(control=data[:,6:24],uniforms=uniforms,speed=data[:,:2],
            tiles=data[:,2:6],expectedControl=data[:,93:111],expectedSpeed=data[:,111:113],
            expectedTiles=data[:,113:117])
        for key,value in arrays.items():np.ascontiguousarray(value).tofile(folder/(key+'.bin'))
        save(folder/'context.json',dict(encodedSteps=meta['encodedSteps'],batchBaseSteps=meta['batchBaseSteps'],
            physicalClockOrigin=item['originTicks'],schema=schema))
        rows.append(dict(id=name,origin=backend,label=name+'-'+backend,folder=str(folder.relative_to(ROOT)),
            frames=len(data),controlBytes=c*4,uniformBytes=u*4,cutCells=name!='made-perimeter-s1-1'))
    for p in HERE.iterdir():
        if p.suffix in ['.py','.swift','.md']:shutil.copyfile(p,ROOT/'analysis'/p.name)
    save(ROOT/'preparation.json',dict(status='frozen-no-GPU',rows=rows,schemas=audit['schemas'],consumed=consumed,
        metalSourceSHA256=sha(ROOT/'analysis/producer-main.metal'),compileOptions='nil; empty constants; linked SDK15.0',
        pins={str(p):sha(p) for p in ROOT.rglob('*') if p.is_file()}))
    print('Frozen6 banks /',sum(r['frames'] for r in rows),'actual records and original full native producers')


if __name__=='__main__':main()
