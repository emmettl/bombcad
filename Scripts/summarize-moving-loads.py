#!/usr/bin/env python3
"""Audit sustained pressure-pulse loads and report grid/CFL differences.

The finest grid is a numerical comparison, not exact truth or blast validation.
"""
import json
import math
import sys
from pathlib import Path
from runpy import run_path

ROOT = Path(__file__).resolve().parent.parent
transition_counts = run_path(str(ROOT / 'Scripts/summarize-moving-trajectory.py'))['transition_counts']


def norm_difference(a, b):
    return math.dist(a, b)/math.hypot(*b)


def main():
    conserved = '--conserved-quadratic' in sys.argv
    suffix = '-conserved' if conserved else ''
    rows = json.loads((ROOT / f'.build/moving-loads{suffix}.json').read_text())
    keys = [(r['cellSize'], r['rotation'], r['cfl']) for r in rows]
    expected = {(h, a, c) for h in (0.2, 0.1, 0.05) for a in (0, 0.23) for c in (0.2, 0.1)}
    assert len(keys) == len(expected) and set(keys) == expected, 'Incomplete or duplicate matrix'
    by_key = dict(zip(keys, rows))
    mass = 1.225*(8-0.8**3)
    for r in rows:
        assert r['duration'] == 0.0002 and r['velocity'] == [300, 100, -40]
        assert math.dist(r['displacement'], [0.06, 0.02, -0.008]) < 1e-11
        assert r['pulseCentre'] == [0.45, 1.18, 1.10] and r['pulseWidth'] == [0.14, 0.18, 0.18]
        assert r['targetPulseEnergy'] == 6400 and abs(r['initialPulseEnergy']-6400) < 1e-7
        assert abs(r['initialMass']-mass) < 1e-10
        energy = 101325*(8-0.8**3)/(1.4-1) + 0.5*mass*(300**2+100**2+40**2) + 6400
        assert abs(r['initialEnergy']-energy) < 1e-7
        assert r['pulseAmplitude'] > 0 and r['maximumInitialPressure'] > 101325
        assert r['transport'] == ('conservedQuadraticHeun' if conserved else 'limitedHeun')
        assert r['wallIntegration'] == 'surfaceTimeQuadrature'
        assert r['maximumRelativeQuadratureVolumeResidual'] < 1e-8
        assert r['maximumRelativeGeometryResidual'] < 1e-8
        assert r['minimumOldGroupFraction'] >= 0.25 and r['minimumFinalGroupFraction'] >= 0.25
        assert r['maximumMembers'] <= 64 and len(r['frames']) == 4
        steps = fallbacks = 0
        for n, f in enumerate(r['frames'], 1):
            assert f['time'] == n*r['duration']/4 and f['steps'] > steps
            assert f['wallSampleFallbacks'] >= fallbacks
            steps, fallbacks = f['steps'], f['wallSampleFallbacks']
            assert f['minimumPressure'] > 0 and f['minimumDensity'] > 0
            assert f['maximumRelativePressureDeparture'] > 0.1 and f['maximumPerturbationSpeed'] > 0.01
            assert abs(f['massBudgetResidual']) < 1e-10 and math.hypot(*f['momentumBudgetResidual']) < 1e-8
            assert abs(f['energyBudgetResidual']) < 1e-6 and abs(f['volumeResidual']) < 1e-10
            assert abs(f['impulseWorkResidual']) < 1e-9
            work = sum(v*i for v, i in zip(r['velocity'], f['bodyImpulse']))
            assert abs(work-f['bodyWork']) < 1e-9
        final = r['frames'][-1]
        counts = transition_counts(dict(r, startPathTime=0))
        assert counts == (r['referenceDryToWetCells'], r['referenceWetToDryCells'])
        assert counts == (final['dryToWetCells'], final['wetToDryCells'])
        assert math.hypot(*final['bodyImpulse']) > 1e-3 and math.hypot(*final['bodyAngularImpulse']) > 1e-4
    for angle in (0, 0.23):
        ref = by_key[0.05, angle, 0.1]['frames'][-1]
        print(f'angle {angle}, fine/CFL 0.1 impulse {ref["bodyImpulse"]}; angular impulse {ref["bodyAngularImpulse"]}')
        for h in (0.2, 0.1, 0.05):
            coarse_time = by_key[h, angle, 0.2]['frames'][-1]
            half_time = by_key[h, angle, 0.1]['frames'][-1]
            i = norm_difference(coarse_time['bodyImpulse'], half_time['bodyImpulse'])
            t = norm_difference(coarse_time['bodyAngularImpulse'], half_time['bodyAngularImpulse'])
            gi = norm_difference(half_time['bodyImpulse'], ref['bodyImpulse'])
            gt = norm_difference(half_time['bodyAngularImpulse'], ref['bodyAngularImpulse'])
            # Four matched cumulative snapshots compare the evolving load history.
            old = by_key[h, angle, 0.1]['frames']
            fine = by_key[0.05, angle, 0.1]['frames']
            hi = sum(math.dist(a['bodyImpulse'], b['bodyImpulse']) for a, b in zip(old,fine))/sum(math.hypot(*f['bodyImpulse']) for f in fine)
            ht = sum(math.dist(a['bodyAngularImpulse'], b['bodyAngularImpulse']) for a, b in zip(old,fine))/sum(math.hypot(*f['bodyAngularImpulse']) for f in fine)
            print(f'dx {h}: CFL-halving impulse/torque {100*i:.3f}%/{100*t:.3f}%; '
                  f'grid vs fine {100*gi:.3f}%/{100*gt:.3f}%; history {100*hi:.3f}%/{100*ht:.3f}%')
        for h in (0.2, 0.1, 0.05):
            a, b = by_key[h,angle,0.2], by_key[h,angle,0.1]
            assert a['initialPulseEnergy'] == b['initialPulseEnergy'] and a['pulseAmplitude'] == b['pulseAmplitude']
    print('All twelve cases pass energy matching, positive states, geometry and gas/reservoir/body budgets.')
    print('Grid/CFL differences are reported, without treating the finest numerical solution as exact.')


if __name__ == '__main__':
    main()
