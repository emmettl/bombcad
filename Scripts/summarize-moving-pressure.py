#!/usr/bin/env python3
"""Check prescribed moving pressure loads against independent closed-form box integrals.

This is a geometry/quadrature probe, not a gas or blast validation.
"""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def cross(a, b):
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]


def main():
    rows = json.loads((ROOT / '.build/moving-pressure.json').read_text())
    keys = [(r['cellSize'], r['rotation'], r['timeSlices']) for r in rows]
    expected = {(h, a, n) for h in (0.4, 0.2, 0.1) for a in (0, 0.23) for n in (1, 4)}
    assert len(keys) == len(expected) and set(keys) == expected, 'Incomplete or duplicate matrix'
    for r in rows:
        assert r['size'] == [0.8, 0.6, 0.4] and r['velocity'] == [300, 100, -40]
        assert r['duration'] == 0.0008 and math.dist(r['initialGeometricCentre'], [1.013, 1.027, 1.041]) < 1e-12
        assert r['pressureCoefficients'] == [101325, 15000, 10000]
        g = r['gradientCoefficients']
        assert g == [[23000, -17000, 31000], [7000, 19000, -11000], [13000, -9000, 17000]]
        # Simpson integrates the quadratic gradient exactly. The divergence theorem
        # supplies the box force without using any clipped patch or reported exact load.
        def gradient(s):
            return [g[0][i] + s*g[1][i] + s*s*g[2][i] for i in range(3)]
        mean = [(a+4*b+c)/6 for a, b, c in zip(gradient(0), gradient(0.5), gradient(1))]
        impulse = [-math.prod(r['size'])*r['duration']*x for x in mean]
        axis = [x/math.sqrt(14) for x in (1, 2, 3)]
        local = [0.08, -0.06, 0.04]
        a = r['rotation']
        ax = cross(axis, local)
        dot = sum(x*y for x, y in zip(axis, local))
        offset = [math.cos(a)*local[i] + math.sin(a)*ax[i] + (1-math.cos(a))*dot*axis[i]
                  for i in range(3)]
        com = [x+d for x, d in zip(r['initialGeometricCentre'], offset)]
        assert math.dist(com, r['initialCentreOfMass']) < 1e-12
        angular = cross([-x for x in offset], impulse)
        work = sum(x*y for x, y in zip(r['velocity'], impulse))
        assert math.dist(r['exactImpulse'], impulse) < 1e-12
        assert math.dist(r['exactAngularImpulse'], angular) < 1e-12 and abs(r['exactWork'] - work) < 1e-10
        for name in ('sampled', 'centroid'):
            f = r[name]
            e = math.dist(f['impulse'], impulse)/math.hypot(*impulse)
            t = math.dist(f['angularImpulse'], angular)/math.hypot(*angular)
            w = abs(f['work'] - work)/abs(work)
            for reported, actual in zip(
                    (f['relativeImpulseError'], f['relativeAngularImpulseError'], f['relativeWorkError']), (e, t, w)):
                assert abs(reported-actual) < 1e-12
            assert abs(f['work'] - sum(x*y for x, y in zip(r['velocity'], f['impulse']))) < 1e-8
            if name == 'sampled':
                assert max(e, t, w) < 1e-10, 'Sampled loads did not match closed-form reference'
        assert r['wallSamples'] > r['wallPatches'] > 0 and r['minimumSamplePressure'] > 0
        assert r['geometryEvaluations'] > 0 and r['maximumIntervals'] > 1
        assert r['maximumRelativeSampleMomentResidual'] < 1e-10 and abs(r['impulseWorkResidual']) < 1e-8
        c, s = r['centroid'], r['sampled']
        print(f"dx {r['cellSize']}, angle {a}, slices {r['timeSlices']}: centroid impulse/torque "
              f"{100*c['relativeImpulseError']:.4f}%/{100*c['relativeAngularImpulseError']:.4f}%; "
              f"sampled {s['relativeImpulseError']:.3g}/{s['relativeAngularImpulseError']:.3g}")
    print('All twelve cases pass exact loads, moving sample moments, positivity and paired work checks.')


if __name__ == '__main__':
    main()
