"""Freeze qualified actual banks, native producer and documented compiler capability."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-selector-contract')
PRIOR = ROOT.parent / '2026-10-22-clock-selector-replay'
SDK = Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''): h.update(b)
    return h.hexdigest()


def load(path): return json.loads(Path(path).read_text())


def save(path, value): Path(path).write_text(json.dumps(value, indent=2) + '\n')


def main():
    ROOT.mkdir(exist_ok=False)
    for name in ['analysis', 'runtime', 'banks', 'capability']: (ROOT / name).mkdir()
    archive = load(HERE.parent / PRIOR.name / 'archive.json')['manifest']
    consumed = {}

    def pin(path):
        assert sha(path) == archive[str(path.relative_to(PRIOR))]['sha256'], path
        consumed[str(path)] = sha(path)
        return path

    prep = load(pin(PRIOR / 'preparation.json'))
    assert load(pin(PRIOR / 'results.json'))['allNativeOwnWordsExact']
    assert load(pin(PRIOR / 'verification.json'))['status'] == 'verified'
    assert load(pin(PRIOR / 'compile.json'))['linkedSDK'] == '15.0'
    shutil.copyfile(pin(PRIOR / 'analysis/producer-main.metal'), ROOT / 'analysis/producer-main.metal')
    rows = prep['rows']
    for row in rows:
        bank = ROOT / row['folder']; bank.mkdir()
        for name in ['control.bin', 'uniforms.bin', 'speed.bin', 'tiles.bin', 'context.json', 'source-order.npy']:
            shutil.copyfile(pin(PRIOR / row['folder'] / name), bank / name)
        origin = row['origin']
        for backend in ['metal', 'cuda']:
            stage = 'own' if backend == origin else 'cross'
            shutil.copyfile(pin(PRIOR / (backend + '-' + stage) / row['label'] / 'outputs.bin'),
                            bank / ('expected-' + backend + '.bin'))
        u = np.fromfile(bank / 'uniforms.bin', dtype='<u4').reshape(-1, 69)
        for field in ['gaugeCount', 'gravity', 'forcedStep']:
            assert np.all(u[:, prep['schemas'][origin]['uniformFields'][field]] == 0)
    header = SDK / 'System/Library/Frameworks/Metal.framework/Versions/A/Headers/MTLLibrary.h'
    text = header.read_text()
    for phrase in ['MTLMathModeSafe', 'MTLMathFloatingPointFunctionsPrecise', 'macos(15.0)']:
        assert phrase in text
    shutil.copyfile(header, ROOT / 'capability/MTLLibrary.h')
    shutil.copyfile('/private/tmp/bombcad-selector-msl.pdf', ROOT / 'capability/Metal-Shading-Language-Specification.pdf')
    shutil.copyfile('/private/tmp/bombcad-selector-msl.txt', ROOT / 'capability/Metal-Shading-Language-Specification.txt')
    save(ROOT / 'capability/receipt.json', dict(header=str(header), headerSHA256=sha(header),
        specificationURL='https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf',
        specificationSHA256=sha(ROOT / 'capability/Metal-Shading-Language-Specification.pdf'),
        date='2026-06-04', section='1.6.3',
        optionContract='mathMode.safe; mathFloatingPointFunctions.precise; contraction within a statement still allowed',
        system=subprocess.check_output(['sw_vers'], text=True),
        kernel=subprocess.check_output(['uname', '-a'], text=True)))
    for p in HERE.iterdir():
        if p.suffix in ['.py', '.swift', '.md']: shutil.copyfile(p, ROOT / 'analysis' / p.name)
    save(ROOT / 'preparation.json', dict(rows=rows, schemas=prep['schemas'], consumed=consumed,
        sourceSHA256=sha(ROOT / 'analysis/producer-main.metal'),
        pins={str(p): sha(p) for p in ROOT.rglob('*') if p.is_file()}))
    print('Frozen six actual banks, native expectations and primary capability evidence')


if __name__ == '__main__': main()
