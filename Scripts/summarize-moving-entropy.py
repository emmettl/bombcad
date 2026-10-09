#!/usr/bin/env python3
"""Check analytical moving-density transport, conservation and spatial/CFL sensitivity."""
import json
import math
import sys
from pathlib import Path
from runpy import run_path

ROOT = Path(__file__).resolve().parent.parent
transition_counts = run_path(str(ROOT / 'Scripts/summarize-moving-trajectory.py'))['transition_counts']


def check(path, mode, integrator='euler', wall_mode='centroid'):
    rows = json.loads(path.read_text())
    expected = {(h, a, c) for h in (0.4, 0.2, 0.1) for a in (0, 0.23) for c in (0.2, 0.1)}
    keys = [(r['cellSize'], r['rotation'], r['cfl']) for r in rows]
    assert len(keys) == len(expected) and set(keys) == expected, 'Incomplete or duplicate matrix'
    errors = {}
    for r in rows:
        key = (r['cellSize'], r['rotation'], r['cfl'])
        assert r.get('reconstruction', 'constant') == mode
        assert r.get('timeIntegration', 'euler') == integrator
        assert r.get('wallIntegration', 'centroid') == wall_mode
        assert r['densityProfile'] == 'quadratic-advection' and r['densityAmplitude'] == 0.2
        assert r['velocity'] == [300, 100, -40] and r['duration'] == 0.0008 and r['startPathTime'] == 0
        assert math.dist(r['displacement'], [0.24, 0.08, -0.032]) < 1e-11
        assert r['minimumOldGroupFraction'] >= 0.25 and r['minimumFinalGroupFraction'] >= 0.25
        assert r['maximumMembers'] <= 64 and len(r['frames']) == 4
        previous_fallbacks = 0
        for n, f in enumerate(r['frames'], 1):
            if wall_mode == 'surfaceTimeQuadrature':
                assert isinstance(f['wallSampleFallbacks'], int) and f['wallSampleFallbacks'] >= previous_fallbacks
                previous_fallbacks = f['wallSampleFallbacks']
            assert f['time'] == n * r['duration'] / 4
            t = f['transport']
            s = 1 + 300 * f['time']
            # Closed-form cube moment; the uniform cube's x variance is rotation invariant.
            mass = 1.225 * 7.488 + 1.225 * 0.2 * (
                32 / 3 - 16*s + 8*s*s - 0.512 * (0.013**2 + 0.8**2 / 12))
            energy = 101325 / (1.4 - 1) * 7.488 + 0.5 * (300**2 + 100**2 + 40**2) * mass
            assert abs(t['referenceMass'] - mass) < 1e-12
            assert abs(t['referenceEnergy'] - energy) < 1e-8
            assert abs(t['referenceQuadratureMassResidual']) < 1e-11
            assert t['relativeDensityL1'] > 0 and t['relativeDensityLInf'] > 0
            assert abs(t['relativeGlobalMassError']) <= t['relativeDensityL1'] + 1e-9
            assert t['minimumDensity'] > 0 and f['minimumPressure'] > 0
            assert f['maximumRelativePressureError'] < 1e-9 and f['maximumVelocityError'] < 1e-7
            assert abs(f['massBudgetResidual']) < 1e-10 and abs(f['energyBudgetResidual']) < 1e-6
            assert math.hypot(*f['momentumBudgetResidual']) < 1e-8 and abs(f['volumeResidual']) < 1e-10
            assert abs(f['impulseWorkResidual']) < 1e-9
        last = r['frames'][-1]
        counts = transition_counts(r)
        assert counts == (last['dryToWetCells'], last['wetToDryCells'])
        assert counts == (r['referenceDryToWetCells'], r['referenceWetToDryCells'])
        errors[key] = last['transport']['relativeDensityL1']
    for angle in (0, 0.23):
        for cfl in (0.2, 0.1):
            e = [errors[h, angle, cfl] for h in (0.4, 0.2, 0.1)]
            assert e[0] > e[1] > e[2], 'Density error did not decrease with grid refinement'
            orders = [math.log2(e[i] / e[i+1]) for i in (0, 1)]
            print(f'angle {angle}, CFL {cfl}: excess-mass L1 '
                  + ' → '.join(f'{100*x:.3f}%' for x in e)
                  + f'; observed rates {orders[0]:.3f}, {orders[1]:.3f}')
    sensitivity = max(abs(errors[h, a, 0.1] / errors[h, a, 0.2] - 1)
                      for h in (0.4, 0.2, 0.1) for a in (0, 0.23))
    print(f'Maximum relative L1 change under CFL halving: {100*sensitivity:.3f}%')
    print(f'{path.name}: all twelve cases pass reference, transition, positivity, conservation and spatial refinement checks.')
    return errors, {key: r for key, r in zip(keys, rows)}


def main():
    baseline, base_rows = check(ROOT / '.build/moving-entropy.json', 'constant')
    if '--limited' in sys.argv or '--heun' in sys.argv or '--surface-quadrature' in sys.argv:
        limited, limited_rows = check(ROOT / '.build/moving-entropy-limited.json', 'limited')
        for key in baseline:
            assert limited[key] < baseline[key], 'Limited reconstruction did not improve density transport'
        for angle in (0, 0.23):
            key = (0.1, angle, 0.1)
            b = base_rows[key]['frames'][-1]['transport']['maximumNewlyWetRelativeDensityError']
            l = limited_rows[key]['frames'][-1]['transport']['maximumNewlyWetRelativeDensityError']
            assert l < b
            print(f'Fine angle {angle}: L1 improvement {baseline[key]/limited[key]:.2f}×; '
                  f'newly wet error {100*b:.3f}% → {100*l:.3f}%')

    if '--heun' in sys.argv or '--surface-quadrature' in sys.argv:
        heun, _ = check(ROOT / '.build/moving-entropy-limited-heun.json', 'limited', 'heun')
        for angle in (0, 0.23):
            for h in (0.4, 0.2, 0.1):
                old_change = abs(limited[h, angle, 0.1] / limited[h, angle, 0.2] - 1)
                new_change = abs(heun[h, angle, 0.1] / heun[h, angle, 0.2] - 1)
                assert new_change < old_change and new_change < 0.005, 'CFL sensitivity did not improve'
                print(f'dx {h}, angle {angle}: relative CFL sensitivity '
                      f'{100*old_change:.3f}% Euler → {100*new_change:.3f}% Heun')
        # Full moving runs include changing partitions and bounded member scatter;
        # report their CFL sensitivity without assuming overall second-order convergence.

    if '--surface-quadrature' in sys.argv:
        sampled, _ = check(ROOT / '.build/moving-entropy-limited-heun-surface-quadrature.json',
                           'limited', 'heun', 'surfaceTimeQuadrature')
        change = max(abs(sampled[k]/heun[k]-1) for k in sampled)
        print(f'Maximum relative density L1 change from sampled walls: {100*change:.3f}%')
        # This mode changes limiter evaluation locations as well as wall integration;
        # constant pressure advection does not measure nonuniform pressure-load accuracy.


if __name__ == '__main__':
    main()
