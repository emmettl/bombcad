#!/usr/bin/env python3
"""Check sustained and original-speed trajectory reports against budgets and a geometric oracle."""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = {(h, a, c) for h in (0.2, 0.1) for a in (0, 0.23) for c in (0.2, 0.1)}


def transition_counts(row):
    # Rodrigues rotation and projected-cube bounds are independent of the Swift clipping,
    # gas quadrature, grouping, fluxes and the reported reference counts.
    angle = row['rotation']
    axis = [x / math.sqrt(14) for x in (1, 2, 3)]
    normals = []
    for j in range(3):
        e = [int(i == j) for i in range(3)]
        cross = [axis[1]*e[2]-axis[2]*e[1], axis[2]*e[0]-axis[0]*e[2], axis[0]*e[1]-axis[1]*e[0]]
        n = [math.cos(angle)*e[i] + math.sin(angle)*cross[i]
             + (1-math.cos(angle))*axis[i]*axis[j] for i in range(3)]
        normals.extend([[-x for x in n], n])
    origin = [x + row['startPathTime']*v for x, v in zip((1.013, 1.027, 1.041), (3, 1, -0.4))]
    h, duration = row['cellSize'], row['duration']
    opening = closing = 0
    for z in range(round(2/h)):
        for y in range(round(2/h)):
            for x in range(round(2/h)):
                centre = [h*(x+0.5), h*(y+0.5), h*(z+0.5)]
                low, high = -math.inf, math.inf
                for n in normals:
                    residual = sum(n[i]*(centre[i]-origin[i]) for i in range(3)) + h/2*sum(map(abs, n)) - 0.4
                    speed = sum(n[i]*row['velocity'][i] for i in range(3))
                    if speed > 0:
                        low = max(low, residual/speed)
                    elif speed < 0:
                        high = min(high, residual/speed)
                    elif residual > 0:
                        high = -math.inf
                if max(low, 0) < min(high, duration):
                    closing += 0 < low < duration
                    opening += 0 < high < duration
    return opening, closing


def check(path, window, mode='constant', integrator='euler', wall_mode='centroid'):
    rows = json.loads(path.read_text())
    keys = [(r['cellSize'], r['rotation'], r['cfl']) for r in rows]
    assert len(keys) == len(EXPECTED) and set(keys) == EXPECTED, 'Incomplete or duplicate case matrix'
    duration, scale = (0.000064, 1) if window else (0.0008, 100)
    for r in rows:
        assert r.get('reconstruction', 'constant') == mode
        assert r.get('timeIntegration', 'euler') == integrator
        assert r.get('wallIntegration', 'centroid') == wall_mode
        assert r['duration'] == duration
        assert r['velocity'] == [scale*v for v in (3, 1, -0.4)]
        assert math.dist(r['displacement'], [duration*v for v in r['velocity']]) < 1e-11
        assert r['minimumOldGroupFraction'] >= 0.25 and r['minimumFinalGroupFraction'] >= 0.25
        assert r['maximumMembers'] <= 64 and r['maximumRelativeGeometryResidual'] < 1e-10
        assert len(r['frames']) == 4
        previous_steps = 0
        previous_fallbacks = 0
        for n, f in enumerate(r['frames'], 1):
            assert f['time'] == n*duration/4 and f['steps'] > previous_steps
            previous_steps = f['steps']
            if wall_mode == 'surfaceTimeQuadrature':
                assert isinstance(f['wallSampleFallbacks'], int) and f['wallSampleFallbacks'] >= previous_fallbacks
                previous_fallbacks = f['wallSampleFallbacks']
            assert f['minimumPressure'] > 0
            assert f['maximumRelativeDensityError'] < 1e-9 and f['maximumRelativePressureError'] < 1e-9
            assert f['maximumVelocityError'] < 1e-7
            assert abs(f['massBudgetResidual']) < 1e-10 and abs(f['volumeResidual']) < 1e-10
            assert math.hypot(*f['momentumBudgetResidual']) < 1e-8 and abs(f['energyBudgetResidual']) < 1e-6
            assert math.hypot(*f['bodyImpulse']) < 1e-8 and math.hypot(*f['bodyAngularImpulse']) < 1e-8
            assert abs(f['bodyWork']) < 1e-6 and abs(f['impulseWorkResidual']) < 1e-9
        last = r['frames'][-1]
        reference = transition_counts(r)
        assert reference == (r['referenceDryToWetCells'], r['referenceWetToDryCells'])
        assert reference == (last['dryToWetCells'], last['wetToDryCells'])
        assert reference[0] > 0 and last['partitionChangedSteps'] > 0
        print(f"dx {r['cellSize']}, angle {r['rotation']}, CFL {r['cfl']}: "
              f"{last['steps']} steps, transitions {reference}, "
              f"pressure error {last['maximumRelativePressureError']:.3g}, fallbacks {last.get('wallSampleFallbacks', 0)}")
    print(f"{path.name}: all eight trajectories pass.")


if __name__ == '__main__':
    limited = '--limited' in sys.argv
    second_order = '--heun' in sys.argv
    sampled = '--surface-quadrature' in sys.argv
    suffix = (('-limited' if limited else '') + ('-heun' if second_order else '')
              + ('-surface-quadrature' if sampled else ''))
    wall_mode = 'surfaceTimeQuadrature' if sampled else 'centroid'
    integrator = 'heun' if second_order else 'euler'
    mode = 'limited' if limited else 'constant'
    check(ROOT / f'.build/moving-trajectory-halving{suffix}.json', window=False, mode=mode, integrator=integrator, wall_mode=wall_mode)
    check(ROOT / f'.build/moving-trajectory-ambient-window-halving{suffix}.json', window=True, mode=mode, integrator=integrator, wall_mode=wall_mode)
