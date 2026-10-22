"""Freeze a native CUDA replay stage and original producer/runtime identities."""
import argparse
import shutil
from prepare import ROOT,HERE,load,save,sha


def main():
    p=argparse.ArgumentParser();p.add_argument('stage',choices=['own','cross']);stage=p.parse_args().stage
    prep=load(ROOT/'preparation.json')
    for mapping in [prep['pins'],prep['consumed']]:
        for path,h in mapping.items():assert sha(path)==h,path
    if stage=='cross':
        for b in ['metal','cuda']:assert load(ROOT/(b+'-own/receipt.json'))['allOwnWordsExact']
    pack=ROOT/('remote-input-'+stage);pack.mkdir(exist_ok=False)
    shutil.copytree(ROOT/'worker',pack/'worker');shutil.copyfile(HERE/'cuda_replay.py',pack/'worker/cuda_replay.py')
    shutil.copytree(ROOT/'banks',pack/'banks')
    if stage=='cross':
        for b in ['metal','cuda']:
            (pack/(b+'-own')).mkdir();shutil.copyfile(ROOT/(b+'-own/receipt.json'),pack/(b+'-own/receipt.json'))
    prior=ROOT.parent/'2026-10-22-clock-selection';receipt=prior/'cuda-own/receipt.json'
    assert sha(receipt)==load(HERE.parent/prior.name/'archive.json')['manifest']['cuda-own/receipt.json']['sha256']
    original=load(receipt)
    config=dict(rows=prep['rows'],sourceSHA256=original['sourceSHA256'],runtimePins=original['selectedRuntimePins'],
        expectedPTX={str(int(x['cutCells'])):x['ptxSHA256'] for x in original['compile']},
        pins={str(p.relative_to(pack)):sha(p) for p in pack.rglob('*') if p.is_file()})
    save(pack/(stage+'.json'),config)
    save(ROOT/('cuda-staging-'+stage+'.json'),dict(stage=stage,pins={str(p):sha(p) for p in pack.rglob('*') if p.is_file()}))
    print('Frozen native CUDA replay stage',stage)


if __name__=='__main__':main()
