"""Independently verify complete recorded banks/outputs and narrow contract gates."""
import subprocess

import numpy as np

from prepare import ROOT, SDK, load, save, sha


def main():
    prep = load(ROOT / 'preparation.json'); result = load(ROOT / 'results.json')
    assert result['status'] == 'complete-all-outcomes'
    for mapping in [prep['pins'], prep['consumed'], result['consumed']]:
        for p, h in mapping.items(): assert sha(p) == h, p
    compile = load(ROOT / 'compile.json')
    first = load(ROOT / 'preflight-attempt-1/compile.json')
    assert first['returncode'] == 0 and first['linkedSDK'] == '27.0'
    assert sha(ROOT / 'preflight-attempt-1/replay') == first['binarySHA256']
    assert first['command'][-3] == compile['command'][-3] == str(ROOT / 'analysis/replay.swift')
    assert sha(ROOT / 'analysis/replay.swift') == compile['sourceSHA256']
    assert compile['returncode'] == 0 and compile['linkedSDK'] == compile['linkedMinOS'] == '15.0'
    assert sha(compile['command'][0]) == compile['compilerSHA256'] == first['compilerSHA256']
    assert sha(ROOT / 'runtime/replay') == compile['binarySHA256']
    capability = load(ROOT / 'capability/receipt.json')
    assert capability['system'] == subprocess.check_output(['sw_vers'], text=True)
    assert capability['kernel'] == subprocess.check_output(['uname', '-a'], text=True)
    assert sha(capability['header']) == capability['headerSHA256']
    fields = prep['schemas']['metal']['controlFields']; total = 0
    stages = {}
    for stage in ['baseline', 'safe-precise']:
        receipt = load(ROOT / ('metal-' + stage) / 'receipt.json')
        process = load(ROOT / ('metal-' + stage + '-process.json'))
        assert process['status'] == 'terminal' and process['returncode'] == 0 and not process.get('timedOut')
        assert receipt['binarySHA256'] == process['binarySHA256'] == compile['binarySHA256']
        assert receipt['sourceSHA256'] == prep['sourceSHA256']
        assert len(receipt['rows']) == 6
        stages[stage] = receipt
    assert stages['baseline']['allBaselineWordsExact'] and stages['baseline']['nilOptions']
    options = stages['safe-precise']['effectiveOptionsReadback']
    assert options['mathMode'] == 0 and options['mathFloatingPointFunctions'] == 1
    assert not stages['safe-precise']['nilOptions']
    for row in prep['rows']:
        bank = ROOT / row['folder']; n = row['frames']; label = row['label']
        expected = np.fromfile(bank / 'expected-metal.bin', dtype='<u4').reshape(n, 24)
        cuda = np.fromfile(bank / 'expected-cuda.bin', dtype='<u4').reshape(n, 20)
        ref = np.load(bank / 'source-order.npy')
        for stage in stages:
            path = ROOT / ('metal-' + stage) / label / 'outputs.bin'
            r = next(r for r in stages[stage]['rows'] if r['label'] == label)
            assert sha(path) == r['outputSHA256'] and r['frames'] == n and r['outputWords'] == n * 24
            words = np.fromfile(path, dtype='<u4').reshape(n, 24)
            if stage == 'baseline': assert np.array_equal(words, expected)
            else:
                assert np.array_equal(words[:, 0], cuda[:, 0])
                assert np.array_equal(words[:, 0], ref[:, 0])
                assert np.array_equal(words[:, fields['stopped']], cuda[:, fields['stopped']])
                assert np.array_equal(words[:, fields['stopped']], ref[:, 1])
                unchanged = [fields['stopped'], 18, 19, 20, 21, 22, 23]
                assert np.array_equal(words[:, unchanged], expected[:, unchanged])
                tile_counters = [fields['activeTiles'], fields['tileSweeps']]
                shared = [i for i in range(20) if i not in tile_counters]
                assert np.array_equal(words[:, shared], cuda[:, shared])
                if row['origin'] == 'cuda': assert np.array_equal(words[:, :20], cuda)
        total += expected.size
    assert total == result['baselineWords'] == 375672
    save(ROOT / 'verification.json', dict(status='verified', baselineWords=total, records=total // 24,
        allFrozenParentAndLocalPinsVerified=True, allOutputReceiptHashesVerified=True,
        bothControllersTerminalZero=True, allCandidateDTAndStopWordsMatch=True,
        preflightSDK27BinaryRetained=True, unchangedSourceAcrossContextRepair=True,
        toolchainAndHostContextUnchanged=True, sourceSHA256=sha(__file__),
        limits='Read-only local verification; no hermetic-driver, instruction, trajectory, physical accuracy, throughput or admission claim.'))
    print('All pins, full baseline words, candidate dt/stops, toolchain/host context and terminal controllers verify')


if __name__ == '__main__': main()
