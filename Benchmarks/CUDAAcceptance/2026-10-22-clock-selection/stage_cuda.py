"""Freeze each declared CUDA stage only after the required native first-dt gates."""
import argparse
import json
from pathlib import Path
import shutil

from prepare import ROOT, HERE, REPLAY, load, save, sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['own', 'cross'])
    stage = parser.parse_args().stage
    prepared = load(ROOT / 'preparation.json')
    for mapping in [prepared['pins'], prepared['consumed']]:
        for p, h in mapping.items():
            assert sha(p) == h, p
    assert load(ROOT / 'metal-own/receipt.json')['allFirstDTGatesPass']
    if stage == 'cross':
        assert load(ROOT / 'cuda-own/receipt.json')['allFirstDTGatesPass']
    pack = ROOT / ('remote-input-' + stage)
    pack.mkdir(exist_ok=False)
    shutil.copytree(ROOT / 'worker', pack / 'worker')
    shutil.copyfile(HERE / 'cuda_replay.py', pack / 'worker/cuda_replay.py')
    shutil.copytree(ROOT / 'cases', pack / 'cases')
    if stage == 'cross':
        for backend in ['metal', 'cuda']:
            shutil.copytree(ROOT / (backend + '-own'), pack / (backend + '-own'))
    prior = load(REPLAY / 'cuda-own/receipt.json')
    archive = load(HERE.parent / REPLAY.name / 'archive.json')['manifest']
    assert sha(REPLAY / 'cuda-own/receipt.json') == archive['cuda-own/receipt.json']['sha256']
    config = dict(rows=prepared['rows'], sourceSHA256=prior['diagnosticSourceSHA256'],
        expectedPTX={str(int(x['cutCells'])): x['ptxSHA256'] for x in prior['compile']},
        runtimePins=prior['selectedRuntimePins'],
        pins={str(p.relative_to(pack)): sha(p) for p in pack.rglob('*') if p.is_file()})
    save(pack / (stage + '.json'), config)
    save(ROOT / ('cuda-staging-' + stage + '.json'), dict(
        pins={str(p): sha(p) for p in pack.rglob('*') if p.is_file()}, stage=stage))
    print('Frozen CUDA stage', stage)


if __name__ == '__main__':
    main()
