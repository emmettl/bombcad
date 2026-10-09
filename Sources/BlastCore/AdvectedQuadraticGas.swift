import simd

/// Exact Euler solution: rho = rho0 [1 + a ((x-u_x t-c)/L)^2], constant p and u.
/// Continuity reduces to scalar advection; momentum and energy follow because u/p are
/// constant and kinetic energy is linear in rho. A box translating at u has no normal
/// relative flow, so its exact wall pressure is p despite the density variation.
struct AdvectedQuadraticGas {
    enum Failure: Error { case invalidDefinition, invalidGeometry }
    let density = 1.225
    let pressure = 101325.0
    let centre = 1.0
    let length = 1.0
    let amplitude: Double
    let velocity: SIMD3<Double>

    init(velocity: SIMD3<Double>, amplitude: Double = 0.2) throws {
        guard amplitude.isFinite, amplitude > 0, amplitude <= 0.5,
            (0..<3).allSatisfy({ velocity[$0].isFinite }), simd_length_squared(velocity).isFinite
        else { throw Failure.invalidDefinition }
        self.velocity = velocity
        self.amplitude = amplitude
    }
    func density(at point: SIMD3<Double>, time: Double) -> Double {
        let coordinate = (point.x - velocity.x * time - centre) / length
        return density * (1 + amplitude * coordinate * coordinate)
    }
    /// Positive degree-two quadrature integrates the exact quadratic density average.
    /// Normalize weights to the authoritative geometry volume, correcting only clipping
    /// roundoff between independent volume formulas, not any physical gas inventory.
    func cell(
        geometry: FractionalBoxGeometry, lower: SIMD3<Double>, cellSize h: Double,
        time: Double, volume: Double
    ) throws -> FractionalGasTransport.Cell {
        guard volume.isFinite && volume >= 0, time.isFinite else { throw Failure.invalidGeometry }
        if volume == 0 { return .init(volume: 0, amount: .zero) }
        let nodes = geometry.gasQuadrature(lower: lower, cellSize: h)
        let weight = nodes.reduce(0) { $0 + $1.weight }
        guard weight > 0 && weight.isFinite else { throw Failure.invalidGeometry }
        let average = nodes.reduce(0) { $0 + $1.weight * density(at: $1.point, time: time) } / weight
        return .init(volume: volume, density: average, velocity: velocity, pressure: pressure)
    }
    /// Exact area/time-averaged external state on a full, fixed Cartesian grid face.
    /// The study keeps the box inside the domain, so every outer opening is a full face.
    func exterior(
        boundary: MovingConnectedGasGroups.Boundary, cellSize h: Double,
        start: Double, duration: Double
    ) throws -> FractionalGasTransport.Cell {
        let face = boundary.geometry
        guard face.owner == 0, abs(face.area - h * h) <= 1e-10 * h * h,
            abs(boundary.meanTime - duration / 2) <= duration * 1e-10
        else { throw Failure.invalidGeometry }
        let midpoint = density(at: face.centroid, time: start + boundary.meanTime)
        let spatialVariance = h * h / 12 * (1 - face.normal.x * face.normal.x)
        let temporalVariance = velocity.x * velocity.x * duration * duration / 12
        let average =
            midpoint + density * amplitude / (length * length) * (spatialVariance + temporalVariance)
        return .init(volume: 1, density: average, velocity: velocity, pressure: pressure)
    }
    /// Closed-form domain integral minus the translating box's invariant density moment.
    /// This oracle uses no cell clipping or quadrature. The box must remain wholly inside
    /// the 2 m cube and move at the reference velocity, with fixed orientation.
    func domainMass(initialBody body: RigidBoxBody, time: Double) -> Double {
        let s = centre + velocity.x * time
        let domainMoment = 32.0 / 3 - 16 * s + 8 * s * s
        let solidVolume = body.size.x * body.size.y * body.size.z
        var variance = 0.0
        for axis in 0..<3 {
            var unit = SIMD3<Double>.zero
            unit[axis] = 1
            let projection = body.orientation.act(unit).x
            variance += body.size[axis] * body.size[axis] / 12 * projection * projection
        }
        let offset = body.worldPoint(.zero).x - centre
        let solidMoment = solidVolume * (offset * offset + variance)
        return density * (8 - solidVolume) + density * amplitude / (length * length)
            * (domainMoment - solidMoment)
    }
}
