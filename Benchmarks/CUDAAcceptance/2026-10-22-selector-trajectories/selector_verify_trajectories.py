"""Fresh full-inventory and gate verification of completed owned district experiments."""
import subprocess
import sys
from pathlib import Path

import numpy as np

from selector_runtime_prepare import ROOT, CAP, load, save, sha, files


def main(repo):
    repo = Path(repo); prep = load(ROOT / 'runtime-preparation.json'); result = load(ROOT / 'trajectory-results.json')
    for mapping in [prep['pins'], prep['consumed'], prep['physicalInputs'], result['consumed']]:
        for path, digest in mapping.items(): assert sha(path) == digest, path
    assert prep['host'] == subprocess.check_output(['sw_vers'], text=True)
    assert prep['linkedSDK'] == prep['linkedMinOS'] == '15.0'
    assert result['status'] == 'complete-all-outcomes' and not result['allCandidatesPassExistingFixedReference']
    checkpoint = load(repo / 'Benchmarks/CUDAAcceptance/2026-10-22-selector-trajectories/implementation-archive.json')
    for name, item in checkpoint['manifest'].items(): assert sha(ROOT / name) == item['sha256'], name
    command_count = 0
    for stage in ['baseline','plain','capture']:
        report = load(ROOT / ('pilots-' + stage + '.json'))
        assert report['status'] == 'complete-all-outcomes' and report['allThreeParityGatesPass'] and report['allOwnedGroupsTerminal']
        assert len(report['commands']) == len(report['rows']) == 3
        for command in report['commands']:
            assert command['returncode'] == 0 and command['ownedGroupTerminal'] and not command.get('timedOut')
            command_count += 1
        for row in report['rows']:
            folder = ROOT / stage / row['id']
            actual = {str(p.relative_to(folder)): dict(sha256=sha(p),bytes=p.stat().st_size) for p in files(folder)}
            assert actual == row['fullFiles']
            if stage == 'baseline':
                old = CAP / 'metal' / row['id']
                for p in old.iterdir():
                    if p.suffix == '.npy' or p.name in ['clock-inputs.bin','clock-inputs.json','pressure-trace.json','pressure-inputs.json','diagnostic-state-hashes.json']:
                        assert sha(folder / p.name) == sha(p)
            if stage == 'capture':
                plain = ROOT / 'plain' / row['id']
                for p in plain.glob('*.npy'): assert sha(folder / p.name) == sha(p)
                assert sha(folder / 'diagnostic-state-hashes.json') == sha(plain / 'diagnostic-state-hashes.json')
    expected = {'made-perimeter-s1-1':[0,0,0],'made-perimeter-s3-1':[0,0,1],'beirut-p0-1':[61,0,0]}
    base = ROOT.parent / '2026-10-22-fixed-terrain-reference'
    for row in result['rows']:
        name = row['id']; original = base / 'cases' / name / 'metal'
        ref = np.load(original / 'targets.npy').astype('float64'); mask = np.load(original / 'mask.npy') != 0
        candidate = np.load(ROOT / 'plain' / name / 'targets.npy').astype('float64')
        for n in ['inputs.npy','mask.npy']:
            assert sha(original / n) == sha(ROOT / 'plain' / name / n)
        counts = []
        locations = []
        for channel in range(3):
            error = np.abs(candidate[channel] - ref[channel]); allowed = .05 + .002 * np.abs(ref[channel])
            bad = np.argwhere(mask & (error > allowed)); counts.append(len(bad))
            locations.extend((channel,int(y),int(x)) for y,x in bad)
        assert counts == expected[name] == row['gates']['plainCandidateAgainstFixedReference']['counts']
        retained = row['gates']['plainCandidateAgainstFixedReference']['allPerValueFailures']
        assert locations == [(r['channel'],r['row'],r['column']) for r in retained]
        assert row['clock']['allActualDTAndStoppedWordsMatchSourceOrder'] and row['clock']['allActualIntegerClockIncrementsExact']
    assert command_count == 9
    assert load(ROOT / 'remaining-native-clock-verified.json')['recomputationExact']
    report = dict(status='fresh-all-inventories-and-gates-verified', numericalCommands=command_count,
        allOwnedNumericalCommandsTerminalZero=True, allBaselineAndCaptureGatesExact=True,
        all542ImplementationCheckpointMembersUnchanged=True, fixedReferenceCandidateFailureCounts=expected,
        sourceSHA256=sha(__file__),
        limits='Local complete output inventories and frozen inputs/context verified. Full analytic states retained; district 3D state fidelity uses whole-buffer hashes, not locally saved full district states. No instruction/continuum/throughput/global-idle or admission claim.')
    save(ROOT / 'trajectory-verification.json', report)
    print('Fresh verification: nine terminal0 commands; all baseline/capture inventories exact; candidate failures0/0/0,0/0/1,61/0/0 retained')


if __name__ == '__main__': main(sys.argv[1])
