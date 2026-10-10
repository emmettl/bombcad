import simd

/// Experimental, mean-preserving reconstruction of all five Euler conserved densities.
/// A fixed local velocity frame reduces kinetic-energy cancellation; the transformation
/// is linear, so retained frame averages also retain lab-frame mass, momentum and energy.
/// One common factor bounds sampled components and enforces sampled EOS admissibility.
/// This never floors or repairs accepted inventories and is not a global positivity proof.
enum ConservedGasReconstruction {
    enum Failure: Error { case invalidGeometry, invalidState }
    struct Sample {
        let centre: SIMD3<Double>
        let covariance: simd_double3x3
        let density: SIMD8<Double>
    }
    struct Fit {
        let cell: Sample
        let velocityFrame: SIMD3<Double>
        let polynomials: [FiniteVolumePressureFit.Fit]
        let factor: Double
        let positivityReduced: Bool
        let rankFallback: Bool

        private func frameDensity(at point: SIMD3<Double>) -> SIMD8<Double> {
            var value = SIMD8<Double>.zero
            for c in 0..<5 {
                let p = polynomials[c]
                value[c] = p.cell.average + factor * (p.value(at: point) - p.cell.average)
            }
            return value
        }
        func state(at point: SIMD3<Double>) -> FractionalGasTransport.Cell {
            .init(volume: 1, amount: transform(frameDensity(at: point), velocity: -velocityFrame))
        }
    }

    static func transform(_ u: SIMD8<Double>, velocity v: SIMD3<Double>) -> SIMD8<Double> {
        var result = u
        let momentum = SIMD3(u[1], u[2], u[3])
        let shifted = momentum - u[0] * v
        result[1] = shifted.x
        result[2] = shifted.y
        result[3] = shifted.z
        result[4] = u[4] - simd_dot(v, momentum) + 0.5 * u[0] * simd_length_squared(v)
        return result
    }

    static func fit(
        cell: Sample, neighbours: [Sample], controls: [SIMD3<Double>], scale: Double,
        boundComponents: Bool = true
    ) throws -> Fit {
        let samples = [cell] + neighbours
        guard scale.isFinite && scale > 0, !controls.isEmpty,
            samples.allSatisfy({ s in
                (0..<3).allSatisfy { s.centre[$0].isFinite }
                    && (0..<3).allSatisfy { c in (0..<3).allSatisfy { s.covariance[c][$0].isFinite } }
            }), controls.allSatisfy({ p in (0..<3).allSatisfy { p[$0].isFinite } }),
            neighbours.allSatisfy({ simd_distance($0.centre, cell.centre) > 0 })
        else { throw Failure.invalidGeometry }
        _ = try FractionalGasTransport.advance(
            samples.map { .init(volume: 1, amount: $0.density) },
            newVolumes: samples.map { _ in 1 }, transfers: [])
        let velocity = SIMD3(cell.density[1], cell.density[2], cell.density[3]) / cell.density[0]
        let frame = samples.map { transform($0.density, velocity: velocity) }
        let mean = frame[0]
        guard admissible(mean, densityFloor: 0, internalFloor: 0) else { throw Failure.invalidState }
        var polynomials: [FiniteVolumePressureFit.Fit] = []
        var factor = 1.0
        var fallback = false
        var stencil: FiniteVolumePressureFit.Stencil?
        for c in 0..<5 {
            let local = FiniteVolumePressureFit.Sample(
                centre: cell.centre, covariance: cell.covariance, average: mean[c])
            let nearby = neighbours.indices.map { n in
                FiniteVolumePressureFit.Sample(
                    centre: neighbours[n].centre, covariance: neighbours[n].covariance,
                    average: frame[n + 1][c])
            }
            let lower = nearby.reduce(mean[c]) { min($0, $1.average) }
            let upper = nearby.reduce(mean[c]) { max($0, $1.average) }
            // Ignore only differences below roundoff in the ORIGINAL conserved data.
            // Otherwise constant rho/u can spuriously throttle a real pressure slope.
            let originalScale = samples.reduce(1.0) { max($0, abs($1.density[c])) }
            let polynomial: FiniteVolumePressureFit.Fit
            if upper - lower <= 128 * Double.ulpOfOne * originalScale {
                polynomial = .init(
                    cell: local, scale: scale, coefficients: [], volumeAware: true,
                    lower: lower, upper: upper, stencilSize: neighbours.count)
            } else {
                if stencil == nil {
                    stencil = .init(cell: local, neighbours: nearby, scale: scale, volumeAware: true)
                }
                polynomial = stencil!.fit(
                    average: mean[c], neighbourAverages: nearby.map(\.average), quadratic: true)
                fallback = fallback || polynomial.degree < 2
            }
            if boundComponents { factor = min(factor, polynomial.limited(at: controls).factor) }
            polynomials.append(polynomial)
        }
        var deltas = [SIMD8<Double>]()
        for point in controls {
            var delta = SIMD8<Double>.zero
            for c in 0..<5 { delta[c] = polynomials[c].value(at: point) - mean[c] }
            deltas.append(delta)
        }
        let densityFloor = 1e-12 * mean[0]
        let momentum = SIMD3(mean[1], mean[2], mean[3])
        let internalFloor = 1e-12 * (mean[4] - 0.5 * simd_length_squared(momentum) / mean[0])
        func accepted(_ theta: Double) -> Bool {
            deltas.allSatisfy {
                admissible(mean + theta * $0, densityFloor: densityFloor, internalFloor: internalFloor)
            }
        }
        let reduced = !accepted(factor)
        if reduced {
            guard accepted(0) else { throw Failure.invalidState }
            var low = 0.0
            var high = factor
            for _ in 0..<48 {
                let mid = (low + high) / 2
                if accepted(mid) { low = mid } else { high = mid }
            }
            factor = 0.99 * low
        }
        let fit = Fit(
            cell: cell, velocityFrame: velocity, polynomials: polynomials, factor: factor,
            positivityReduced: reduced, rankFallback: fallback)
        // Verify lab-frame EOS as well: the inverse boost can lose internal energy at
        // extreme velocities. Refuse such traces rather than hiding lost energy.
        _ = try FractionalGasTransport.advance(
            controls.map { fit.state(at: $0) }, newVolumes: controls.map { _ in 1 }, transfers: [])
        return fit
    }

    private static func admissible(_ u: SIMD8<Double>, densityFloor: Double, internalFloor: Double) -> Bool {
        guard (0..<8).allSatisfy({ u[$0].isFinite }), u[0] > densityFloor else { return false }
        let momentum = SIMD3(u[1], u[2], u[3])
        let internalEnergy = u[4] - 0.5 * simd_length_squared(momentum) / u[0]
        return internalEnergy.isFinite && internalEnergy > internalFloor
    }
}
