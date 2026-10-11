import Testing
import simd

@testable import BlastCore

@Suite("Diagnostic finite-volume pressure fits")
struct FiniteVolumePressureFitTests {
    private func polynomial(_ p: SIMD3<Double>) -> Double {
        1.2 + 2 * p.x - 3 * p.y + 0.7 * p.z + 0.9 * p.x * p.x - 0.4 * p.y * p.y
            + 0.3 * p.z * p.z + 1.1 * p.x * p.y - 0.6 * p.x * p.z + 0.4 * p.y * p.z
    }

    private func nodes(_ centre: SIMD3<Double>, _ index: Int) -> [SIMD3<Double>] {
        let rotation = simd_quatd(angle: 0.1 * Double(index), axis: simd_normalize(SIMD3(1.0, 2, 3)))
        let halfWidth = SIMD3<Double>(0.08 + 0.006 * Double(index), 0.13, 0.06 + 0.002 * Double(index))
        return (0..<8).map { n in
            centre
                + rotation.act(
                    halfWidth * SIMD3<Double>(n & 1 == 0 ? -1 : 1, n & 2 == 0 ? -1 : 1, n & 4 == 0 ? -1 : 1)
                        / sqrt(3.0))
        }
    }

    private func sample(_ centre: SIMD3<Double>, _ index: Int, linear: Bool = false)
        -> FiniteVolumePressureFit.Sample
    {
        let points = nodes(centre, index)
        var covariance = FiniteVolumePressureFit.zero
        for p in points {
            let d = p - centre
            covariance += simd_double3x3(columns: (d * d.x, d * d.y, d * d.z)) * (1.0 / 8)
        }
        let average =
            points.reduce(0) { $0 + (linear ? 2 + 3 * $1.x - 0.7 * $1.y + 1.1 * $1.z : polynomial($1)) } / 8
        return .init(centre: centre, covariance: covariance, average: average)
    }

    private func stencil(linear: Bool = false) -> [FiniteVolumePressureFit.Sample] {
        var samples: [FiniteVolumePressureFit.Sample] = []
        for z in [-1.1, 0, 0.9] {
            for y in [-0.7, 0, 1.3] {
                for x in [-1.3, 0, 0.8] {
                    samples.append(sample(SIMD3(17 + x, -8 + y, 31 + z), samples.count, linear: linear))
                }
            }
        }
        return samples
    }

    @Test("Quadratic volume-average fitting reproduces an independent polynomial on unequal rotated volumes")
    func quadratic() {
        let samples = stencil()
        let local = samples[13]
        let neighbours = samples.enumerated().filter { $0.offset != 13 }.map(\.element)
        let fit = FiniteVolumePressureFit.fit(
            cell: local, neighbours: neighbours, scale: 0.4, quadratic: true, volumeAware: true)
        #expect(fit.degree == 2)
        for offset in [SIMD3<Double>(0.2, -0.1, 0.17), SIMD3(-0.3, 0.4, -0.2), .zero] {
            let point = local.centre + offset
            #expect(abs(fit.value(at: point) - polynomial(point)) < 1e-9)
        }
        let recoveredAverage = nodes(local.centre, 13).reduce(0) { $0 + fit.value(at: $1) } / 8
        #expect(abs(recoveredAverage - local.average) < 1e-10)
        let pointFit = FiniteVolumePressureFit.fit(
            cell: local, neighbours: neighbours, scale: 0.4, quadratic: true, volumeAware: false)
        #expect(abs(pointFit.value(at: local.centre) - polynomial(local.centre)) > 1e-4)
    }

    @Test("Fits are independent of coordinate scale and neighbour ordering")
    func scaleAndOrder() {
        let samples = stencil()
        let local = samples[13]
        let neighbours = samples.enumerated().filter { $0.offset != 13 }.map(\.element)
        let a = FiniteVolumePressureFit.fit(
            cell: local, neighbours: neighbours, scale: 0.1, quadratic: true, volumeAware: true)
        let b = FiniteVolumePressureFit.fit(
            cell: local, neighbours: neighbours.reversed(), scale: 2, quadratic: true, volumeAware: true)
        let point = local.centre + SIMD3(0.13, -0.27, 0.08)
        #expect(abs(a.value(at: point) - b.value(at: point)) < 1e-9)
    }

    @Test("Affine fields survive varying volume moments with either polynomial degree")
    func affine() {
        let samples = stencil(linear: true)
        let local = samples[13]
        let neighbours = samples.enumerated().filter { $0.offset != 13 }.map(\.element)
        let point = local.centre + SIMD3(0.13, -0.27, 0.08)
        for quadratic in [false, true] {
            let fit = FiniteVolumePressureFit.fit(
                cell: local, neighbours: neighbours, scale: 0.2, quadratic: quadratic, volumeAware: true)
            #expect(abs(fit.value(at: point) - (2 + 3 * point.x - 0.7 * point.y + 1.1 * point.z)) < 1e-10)
        }
    }

    @Test("Insufficient quadratic rank falls back to linear, and planar rank to a constant")
    func rank() {
        let local = sample(.zero, 0, linear: true)
        let axes = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let neighbours = (axes + axes.map { -$0 }).enumerated().map {
            sample($0.element, $0.offset, linear: true)
        }
        let linear = FiniteVolumePressureFit.fit(
            cell: local, neighbours: neighbours, scale: 1, quadratic: true, volumeAware: true)
        #expect(linear.degree == 1)
        #expect(abs(linear.value(at: SIMD3(0.1, 0.2, 0.3)) - 2.49) < 1e-10)
        let constant = FiniteVolumePressureFit.fit(
            cell: local, neighbours: neighbours.filter { $0.centre.z == 0 }, scale: 1,
            quadratic: true, volumeAware: true)
        #expect(constant.degree == 0 && constant.value(at: SIMD3(1, 2, 3)) == local.average)
    }

    @Test("Wall probe reports finite volume-fit loads without changing the baseline traces")
    func probe() throws {
        let base = try ExperimentalInitialWallTraceStudy.run(cellSizes: [0.2], rotations: [0.23])[0]
        let row = try ExperimentalInitialWallTraceStudy.run(
            cellSizes: [0.2], rotations: [0.23], volumeFits: true)[0]
        #expect(base.volumeFits == nil && base.halfDurationVolumeFits == nil)
        #expect(base.limited.force == row.limited.force && base.limited.torque == row.limited.torque)
        let full = row.volumeFits!
        #expect(
            full.modes.map(\.kind) == [
                "twoRingLinear", "pointQuadratic", "volumeQuadratic",
                "volumeQuadraticWallBounded", "volumeQuadraticBounded",
            ])
        #expect(full.maximumMomentResidual < 1e-8 && full.meanStencilSize > 9)
        #expect(full.quadraticFallbackAreaFraction >= 0 && full.quadraticFallbackAreaFraction <= 1)
        for (a, b) in zip(full.modes, row.halfDurationVolumeFits!.modes) {
            #expect(a.minimumPressure.isFinite && a.maximumPressure.isFinite)
            #expect(a.loads.relativePressureL1 >= 0)
            #expect(simd_distance(a.loads.force, b.loads.force) / simd_length(row.referenceForce) < 1e-5)
            #expect(simd_distance(a.loads.torque, b.loads.torque) / simd_length(row.referenceTorque) < 1e-5)
            if a.kind.hasSuffix("Bounded") {
                #expect(a.outsideStencilAreaFraction == 0 && a.negativeExcessAreaFraction == 0)
            }
        }
        for bound in full.bounds! + row.halfDurationVolumeFits!.bounds! {
            #expect(bound.meanFactor >= 0 && bound.meanFactor <= 1)
            #expect(bound.activeAreaFraction >= 0 && bound.activeAreaFraction <= 1)
            #expect(bound.maximumRelativeAverageResidual < 1e-10)
            #expect(bound.maximumRelativeBoundViolation < 1e-12)
        }
    }

    @Test("An active common bound retains the independent volume average on an unequal rotated volume")
    func activeBound() {
        let samples = stencil()
        let local = samples[13]
        let raw = FiniteVolumePressureFit.fit(
            cell: local,
            neighbours: samples.enumerated().filter { $0.offset != 13 }.map(\.element),
            scale: 0.4, quadratic: true, volumeAware: true)
        let volumePoints = nodes(local.centre, 13)
        let controls = volumePoints + [local.centre + SIMD3(5, -6, 3), local.centre + SIMD3(-4, 2, -3)]
        let limited = raw.limited(at: controls)
        #expect(limited.factor > 0 && limited.factor < 1)
        for p in controls {
            #expect(limited.value(at: p) >= raw.lower - 1e-10)
            #expect(limited.value(at: p) <= raw.upper + 1e-10)
        }
        let recovered = volumePoints.reduce(0) { $0 + limited.value(at: $1) } / 8
        #expect(abs(recovered - local.average) < 1e-10)
        let point = local.centre + SIMD3(0.2, -0.1, 0.17)
        #expect(abs(raw.value(at: point) - polynomial(point)) < 1e-9)
    }

    @Test("Inactive and zero-width bounds retain the original polynomial or the constant average")
    func inactiveAndConstantBounds() {
        let cell = FiniteVolumePressureFit.Sample(
            centre: .zero, covariance: simd_double3x3(diagonal: SIMD3(repeating: 1.0 / 3)), average: 2)
        let coefficients = [1.0, -0.5, 0.2, 2, -0.7, 0.3, 0.6, -0.2, 0.1]
        let raw = FiniteVolumePressureFit.Fit(
            cell: cell, scale: 1, coefficients: coefficients, volumeAware: true,
            lower: -100, upper: 100, stencilSize: 26)
        let points = nodes(.zero, 3)
        let inactive = raw.limited(at: points)
        #expect(inactive.factor == 1)
        #expect(points.allSatisfy { inactive.value(at: $0) == raw.value(at: $0) })
        let constant = FiniteVolumePressureFit.Fit(
            cell: cell, scale: 1, coefficients: coefficients, volumeAware: true,
            lower: 2, upper: 2, stencilSize: 26
        ).limited(at: points)
        #expect(constant.factor == 0)
        #expect(points.allSatisfy { constant.value(at: $0) == 2 })
    }
}
