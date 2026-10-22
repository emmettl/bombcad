"""Independent read-only parity audit; never starts or repeats a physical job."""
import json
from pathlib import Path

import numpy as np

from prepare import ROOT, load, save, sha


def main():
    prep = load(ROOT / 'preparation.json')
    for path, digest in prep['consumed'].items():
        assert sha(path) == digest, path
    receipts = [load(ROOT / name) for name in ['capture.json', 'capture-resume.json']]
    commands = [c for receipt in receipts for c in receipt['commands']]
    assert len(commands) == 4
    assert all(c['returncode'] == 0 and c['ownedGroupTerminal'] for c in commands)
    rows = []
    for planned in prep['rows']:
        folder = ROOT / planned['mode'] / planned['id']
        parent = Path(planned['parentFolder'])
        ordinary = {n: sha(folder / n) == sha(parent / n) for n in [
            'inputs.npy', 'mask.npy', 'targets.npy', 'diagnostic-state-hashes.json',
            'clock-inputs.bin', 'clock-inputs.json']}
        histories = {}
        for stem in ['pressure-trace', 'pressure-inputs']:
            info, old = load(folder / (stem + '.json')), load(parent / (stem + '.json'))
            assert info['columns'] == planned['columns']
            positions = [info['columns'].index(c) for c in old['columns']]
            a, b = np.load(folder / (stem + '.npy')), np.load(parent / (stem + '.npy'))
            histories[stem] = dict(oldWordsExact=np.array_equal(a[:, positions].view('<u4'), b.view('<u4')),
                axesExact=all(info[k] == old[k] for k in ['steps', 'times', 'fields']))
        info, old = load(folder / 'pressure-inputs.json'), load(parent / 'pressure-inputs.json')
        positions = [info['columns'].index(c) for c in old['columns']]
        a, b = np.load(folder / 'pressure-input-endpoints.npy'), np.load(parent / 'pressure-input-endpoints.npy')
        endpoints = np.array_equal(a[:, positions].view('<u4'), b.view('<u4'))
        metadata = None
        if planned['mode'] == 'selector':
            metadata = dict(bytesExact=(folder / 'step-selector.json').read_bytes() == (parent / 'step-selector.json').read_bytes(),
                allParsedValuesExact=load(folder / 'step-selector.json') == load(parent / 'step-selector.json'))
            assert metadata['allParsedValuesExact']
        assert all(ordinary.values()) and endpoints and all(all(h.values()) for h in histories.values())
        rows.append(dict(mode=planned['mode'], id=planned['id'], ordinaryExact=ordinary,
            histories=histories, oldEndpointsExact=endpoints, selectorMetadata=metadata,
            files={p.name: dict(sha256=sha(p), bytes=p.stat().st_size) for p in folder.iterdir() if p.is_file()}))
    result = dict(allFourExpandedGatesPass=True, allFourPhysicalCommandsTerminal0=True,
        controllerStop='Original controller stopped on JSON key order, not numerical parity; three completed jobs preserved, only missing fourth dispatched by resume.py.',
        noNumericalRetries=True, rows=rows)
    save(ROOT / 'verification.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=2))


if __name__ == '__main__':
    main()
