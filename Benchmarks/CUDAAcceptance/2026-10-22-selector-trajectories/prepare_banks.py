"""Freeze qualified actual banks for replay through the solver's real pipeline objects."""
import json
from pathlib import Path
import shutil

import numpy as np

from run_tests import HERE, ROOT, save, sha


def load(path): return json.loads(Path(path).read_text())


def main():
    prior = ROOT.parent / '2026-10-22-selector-contract'
    archive = load(HERE.parent / prior.name / 'archive.json')['manifest']
    consumed = {}

    def pin(path):
        assert sha(path) == archive[str(path.relative_to(prior))]['sha256'], path
        consumed[str(path)] = sha(path)
        return path

    prep = load(pin(prior / 'preparation.json'))
    assert load(pin(prior / 'verification.json'))['status'] == 'verified'
    result = load(pin(prior / 'results.json'))
    assert result['allCandidateDTWordsMatchCUDAAndSourceOrder'] and result['baselineWords'] == 375672
    root = ROOT / 'native-banks'; root.mkdir(exist_ok=False)
    for row in prep['rows']:
        folder = root / row['folder']; folder.mkdir(parents=True, exist_ok=False)
        for name in ['control.bin', 'uniforms.bin', 'speed.bin', 'tiles.bin', 'context.json']:
            shutil.copyfile(pin(prior / row['folder'] / name), folder / name)
        u = np.fromfile(folder / 'uniforms.bin', dtype='<u4').reshape(-1, 69)
        for key in ['gaugeCount', 'gravity', 'forcedStep']:
            assert np.all(u[:, prep['schemas'][row['origin']]['uniformFields'][key]] == 0)
        for mode, stage in [('baseline', 'baseline'), ('precise', 'safe-precise')]:
            shutil.copyfile(pin(prior / ('metal-' + stage) / row['label'] / 'outputs.bin'),
                            folder / ('expected-' + mode + '.bin'))
    save(root / 'parent-pins.json', dict(consumed=consumed, sourceSHA256=prep['sourceSHA256']))
    save(root / 'bank-preparation.json', dict(rows=prep['rows'], sourceSHA256=prep['sourceSHA256'],
        pins={str(p): sha(p) for p in root.rglob('*') if p.is_file()}))
    print('Frozen six actual banks and both complete archived 24-word output sets')


if __name__ == '__main__': main()
