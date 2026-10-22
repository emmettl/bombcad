"""Pin the exact immutable mode controls and runtime before expanding observation indices."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-selector-failure-histories')
PARENT = ROOT.parent / '2026-10-22-selector-trajectories'
COLUMNS = {'made-perimeter-s3-1':[134058,250097,244192], 'beirut-p0-1':[187747,161319,164878,165390]}


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def load(path):return json.loads(Path(path).read_text())


def save(path,value):Path(path).write_text(json.dumps(value,indent=2)+'\n')


def main():
    ROOT.mkdir(exist_ok=False);(ROOT/'analysis').mkdir()
    archive=load(HERE.parent/PARENT.name/'archive.json')['manifest'];consumed={}
    def pin(p):
        assert sha(p)==archive[str(p.relative_to(PARENT))]['sha256'],p
        consumed[str(p)]=sha(p);return p
    runtime=load(pin(PARENT/'runtime-preparation.json'))
    assert load(pin(PARENT/'trajectory-verification.json'))['allBaselineAndCaptureGatesExact']
    for p,h in runtime['pins'].items():assert sha(pin(Path(p)))==h,p
    for p,h in runtime['physicalInputs'].items():assert sha(p)==h;consumed[p]=h
    rows=[]
    for mode,stage in [('original','baseline'),('selector','capture')]:
        report=load(pin(PARENT/('pilots-'+stage+'.json')))
        assert report['allThreeParityGatesPass'] and report['allOwnedGroupsTerminal']
        for name,columns in COLUMNS.items():
            original=next(c['command'] for c in report['commands'] if c['command'][c['command'].index('--id')+1]==name)
            folder=PARENT/stage/name
            for p in folder.iterdir():
                if p.is_file():pin(p)
            rows.append(dict(id=name,mode=mode,columns=columns,parentStage=stage,parentFolder=str(folder),command=original))
    exe=PARENT/'runtime-metal/scenebench';linked=subprocess.check_output(['otool','-l',str(exe)],text=True)
    (ROOT/'linked-sdk.txt').write_text(linked)
    assert 'minos 15.0' in linked and 'sdk 15.0' in linked
    for p in HERE.iterdir():
        if p.suffix in ['.py','.md']:shutil.copyfile(p,ROOT/'analysis'/p.name)
    save(ROOT/'preparation.json',dict(rows=rows,consumed=consumed,runtimeRevision=runtime['revision'],
        producerSourceSHA256=runtime['producerSourceSHA256'],host=subprocess.check_output(['sw_vers'],text=True),
        pins={str(p):sha(p) for p in (ROOT/'analysis').iterdir() if p.is_file()}))
    print('Four observation-only rows frozen; immutable runtime8b393c81/SDK15 and all parent control files verified')


if __name__=='__main__':main()
