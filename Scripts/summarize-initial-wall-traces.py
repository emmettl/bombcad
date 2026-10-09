#!/usr/bin/env python3
"""Independent whole-face Simpson integration audits initial Gaussian wall traces.

No clipped geometry, gas averaging, grouped reconstruction or Swift Gauss rule is reused.
"""
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CENTRE = [1.013, 1.027, 1.041]
PULSE = [0.45, 1.18, 1.10]
WIDTH = [0.14, 0.18, 0.18]


def cross(a, b):
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]


def basis(angle):
    axis = [x/math.sqrt(14) for x in (1, 2, 3)]
    result = []
    for j in range(3):
        unit = [int(i == j) for i in range(3)]
        c = cross(axis, unit)
        result.append([math.cos(angle)*unit[i]+math.sin(angle)*c[i]
                       +(1-math.cos(angle))*axis[i]*axis[j] for i in range(3)])
    return result


def reference(angle, count):
    axes = basis(angle)
    step = 0.8/count
    nodes = [(-0.4+i*step, step/3*(1 if i in (0,count) else (4 if i%2 else 2)))
             for i in range(count+1)]
    force, torque = [0.,0.,0.], [0.,0.,0.]
    for axis in range(3):
        a, b = (axis+1)%3, (axis+2)%3
        for sign in (-1,1):
            integral, moment = 0., [0.,0.,0.]
            for u, wu in nodes:
                base = [sign*0.4*axes[axis][i]+u*axes[a][i] for i in range(3)]
                for v, wv in nodes:
                    offset = [base[i]+v*axes[b][i] for i in range(3)]
                    q = [(CENTRE[i]+offset[i]-PULSE[i])/WIDTH[i] for i in range(3)]
                    weight = wu*wv*math.exp(-0.5*sum(x*x for x in q))
                    integral += weight
                    for i in range(3):
                        moment[i] += weight*offset[i]
            inward = [-sign*x for x in axes[axis]]
            t = cross(moment, inward)
            for i in range(3):
                force[i] += integral*inward[i]
                torque[i] += t[i]
    return force, torque


def relative(a, b):
    return math.dist(a,b)/math.hypot(*b)


def main():
    decompose = '--decompose' in sys.argv
    volume_fit = '--volume-fit' in sys.argv
    suffix = '-volume-fit' if volume_fit else ('-decomposition' if decompose else '')
    rows = json.loads((ROOT / f'.build/initial-wall-traces{suffix}.json').read_text())
    expected = {(h,a) for h in (0.2,0.1,0.05) for a in (0,0.23)}
    keys = [(r['cellSize'],r['rotation']) for r in rows]
    assert len(keys) == len(expected) and set(keys) == expected
    refs = {}
    for angle in (0,0.23):
        low, high = reference(angle,128), reference(angle,256)
        assert max(relative(a,b) for a,b in zip(low,high)) < 1e-6
        refs[angle] = high
    duration_changes = []
    for r in rows:
        assert r['boxSize'] == [0.8,0.8,0.8] and r['bodyCentre'] == CENTRE
        assert r['pulseCentre'] == PULSE and r['pulseWidth'] == WIDTH and r['targetPulseEnergy'] == 6400
        assert r['velocity'] == [300,100,-40] and r['duration'] == r['cellSize']*1e-9
        assert r['pulseAmplitude'] > 0 and r['wallSamples'] > 0 and r['groups'] > 0 and r['maximumMembers'] <= 64
        f, t = refs[r['rotation']]
        force = [r['pulseAmplitude']*x for x in f]
        torque = [r['pulseAmplitude']*x for x in t]
        assert relative(r['referenceForce'],force) < 1e-7
        assert relative(r['referenceTorque'],torque) < 1e-7
        assert r['referenceOrderDifference'] < 1e-8
        for name in ('supplied','constant','limited','halfDurationSupplied','halfDurationConstant','halfDurationLimited'):
            x = r[name]
            assert abs(x['relativeForceError']-relative(x['force'],r['referenceForce'])) < 1e-12
            assert abs(x['relativeTorqueError']-relative(x['torque'],r['referenceTorque'])) < 1e-12
            assert abs(x['power']-sum(v*y for v,y in zip(r['velocity'],x['force']))) < 1e-8
            assert x['relativePressureL1'] >= 0
        for full, half in (('supplied','halfDurationSupplied'),('constant','halfDurationConstant'),('limited','halfDurationLimited')):
            change = max(math.dist(r[full]['force'],r[half]['force'])/math.hypot(*r['referenceForce']),
                         math.dist(r[full]['torque'],r[half]['torque'])/math.hypot(*r['referenceTorque']))
            assert change < 1e-5, 'Probe duration materially changed the diagnostic'
            duration_changes.append(change)
        assert r['supplied']['relativePressureL1'] == 0
        assert r['supplied']['relativeForceError'] < r['limited']['relativeForceError']
        print(f"dx {r['cellSize']}, angle {r['rotation']}: force/torque errors "
              + '; '.join(f"{n} {100*r[n]['relativeForceError']:.4f}%/{100*r[n]['relativeTorqueError']:.4f}%"
                          for n in ('supplied','constant','limited'))
              + f"; limited pressure L1 {100*r['limited']['relativePressureL1']:.3f}%")
    if decompose:
        kinds = {'supplied','constant','leastSquares','limited','centroidConstant','centroidLeastSquares',
                 'centroidLimited','analyticTaylor','averageAnalyticGradient'}
        for r in rows:
            full, half = r['decomposition'], r['halfDurationDecomposition']
            a, b = ({m['kind']: m for m in d['modes']} for d in (full,half))
            assert len(full['modes']) == len(kinds) and set(a) == kinds and set(b) == kinds
            for name in ('meanPressureLimiterFactor','limiterActiveAreaFraction',
                         'rankDeficientAreaFraction','centroidDataLimiterFactor'):
                assert 0 <= full[name] <= 1
            print(f"Decomposition dx {r['cellSize']}, angle {r['rotation']}: "
                  f"area-weighted limiter factor {full['meanPressureLimiterFactor']:.3f}, "
                  f"rank-deficient area {100*full['rankDeficientAreaFraction']:.3f}%")
            for kind in sorted(kinds):
                x = a[kind]
                loads = x['loads']
                assert math.isfinite(x['minimumPressure']) and math.isfinite(x['maximumPressure'])
                assert x['minimumPressure'] <= x['maximumPressure'] and x['nonpositivePressureSamples'] >= 0
                assert 0 <= x['negativeExcessAreaFraction'] <= 1 and 0 <= x['outsideStencilAreaFraction'] <= 1
                assert abs(loads['relativeForceError']-relative(loads['force'],r['referenceForce'])) < 1e-12
                assert abs(loads['relativeTorqueError']-relative(loads['torque'],r['referenceTorque'])) < 1e-12
                assert loads['relativePressureL1'] >= 0
                assert abs(loads['power']-sum(v*y for v,y in zip(r['velocity'],loads['force']))) < 1e-8
                change = max(math.dist(loads['force'],b[kind]['loads']['force'])/math.hypot(*r['referenceForce']),
                             math.dist(loads['torque'],b[kind]['loads']['torque'])/math.hypot(*r['referenceTorque']))
                assert change < 1e-5
                duration_changes.append(change)
                if kind in ('constant','limited','supplied'):
                    assert math.dist(loads['force'],r[kind]['force']) < 1e-8
                    assert math.dist(loads['torque'],r[kind]['torque']) < 1e-8
                if kind in ('constant','limited','centroidConstant','centroidLimited'):
                    assert x['outsideStencilAreaFraction'] < 1e-8
                print(f"  {kind}: force/torque/L1 "
                      f"{100*loads['relativeForceError']:.3f}%/{100*loads['relativeTorqueError']:.3f}%/"
                      f"{100*loads['relativePressureL1']:.3f}%; below-ambient area "
                      f"{100*x['negativeExcessAreaFraction']:.2f}%")
        print('Diagnostic replacements are not an additive error budget or an enabled transport policy.')
    if volume_fit:
        bounded_kinds = {'volumeQuadraticWallBounded', 'volumeQuadraticBounded'}
        kinds = {'twoRingLinear', 'pointQuadratic', 'volumeQuadratic'} | bounded_kinds
        for r in rows:
            full, half = r['volumeFits'], r['halfDurationVolumeFits']
            a, b = ({m['kind']: m for m in d['modes']} for d in (full,half))
            assert len(full['modes']) == len(half['modes']) == len(kinds) and set(a) == set(b) == kinds
            for d in (full, half):
                assert 0 <= d['maximumMomentResidual'] < 1e-8 and d['meanStencilSize'] > 0
                for key in ('quadraticFallbackAreaFraction','pointQuadraticFallbackAreaFraction',
                            'linearFallbackAreaFraction'):
                    assert 0 <= d[key] <= 1
                bounds = {x['kind']: x for x in d['bounds']}
                assert len(d['bounds']) == 2 and set(bounds) == bounded_kinds
                for bound in bounds.values():
                    assert 0 <= bound['meanFactor'] <= 1 and 0 <= bound['activeAreaFraction'] <= 1
                    assert 0 <= bound['maximumRelativeAverageResidual'] < 1e-10
                    assert 0 <= bound['maximumRelativeBoundViolation'] < 1e-12
                assert bounds['volumeQuadraticBounded']['meanFactor'] <= bounds['volumeQuadraticWallBounded']['meanFactor'] + 1e-12
            print(f"Volume fits dx {r['cellSize']}, angle {r['rotation']}: "
                  f"mean stencil size {full['meanStencilSize']:.2f}, "
                  f"quadratic fallback area {100*full['quadraticFallbackAreaFraction']:.2f}%, "
                  f"moment residual {full['maximumMomentResidual']:.3g}")
            for kind in sorted(kinds):
                for x in (a[kind], b[kind]):
                    loads = x['loads']
                    assert math.isfinite(x['minimumPressure']) and math.isfinite(x['maximumPressure'])
                    assert x['minimumPressure'] <= x['maximumPressure']
                    assert isinstance(x['nonpositivePressureSamples'], int) and x['nonpositivePressureSamples'] >= 0
                    for key in ('negativeExcessAreaFraction', 'outsideStencilAreaFraction'):
                        assert 0 <= x[key] <= 1
                    if kind in bounded_kinds:
                        assert x['outsideStencilAreaFraction'] == 0 and x['negativeExcessAreaFraction'] == 0
                        assert x['nonpositivePressureSamples'] == 0
                    assert abs(loads['relativeForceError']-relative(loads['force'],r['referenceForce'])) < 1e-12
                    assert abs(loads['relativeTorqueError']-relative(loads['torque'],r['referenceTorque'])) < 1e-12
                    assert math.isfinite(loads['relativePressureL1']) and loads['relativePressureL1'] >= 0
                    assert abs(loads['power']-sum(v*y for v,y in zip(r['velocity'],loads['force']))) < 1e-8
                x = a[kind]
                loads = x['loads']
                change = max(math.dist(loads['force'],b[kind]['loads']['force'])/math.hypot(*r['referenceForce']),
                             math.dist(loads['torque'],b[kind]['loads']['torque'])/math.hypot(*r['referenceTorque']))
                assert change < 1e-5
                duration_changes.append(change)
                print(f"  {kind}: force/torque/L1 "
                      f"{100*loads['relativeForceError']:.3f}%/{100*loads['relativeTorqueError']:.3f}%/"
                      f"{100*loads['relativePressureL1']:.3f}%; below-ambient/stencil-violation area "
                      f"{100*x['negativeExcessAreaFraction']:.2f}%/{100*x['outsideStencilAreaFraction']:.2f}%; "
                      f"minimum absolute pressure {x['minimumPressure']:.1f} Pa")
            for bound in full['bounds']:
                print(f"  {bound['kind']}: mean factor {bound['meanFactor']:.3f}, "
                      f"active area {100*bound['activeAreaFraction']:.2f}%, "
                      f"average/bound residual {bound['maximumRelativeAverageResidual']:.3g}/"
                      f"{bound['maximumRelativeBoundViolation']:.3g}")
        print('Raw fits share neighbours and weights. Both bounded modes scale the same volume-aware polynomial about its group average.')
        print('Bounds apply at audited control points, not everywhere between them. All five modes remain read-only diagnostics.')
    print(f'Maximum half-duration load change / reference norm: {max(duration_changes):.3g}')
    print('All six probes pass independent face integrals, reported errors and duration sensitivity checks.')
    print('These are initial traces; the evolved pressure-load study still needs separate spatial checks.')


if __name__ == '__main__':
    main()
