import simd

/// First-order ideal-gas Rusanov flux for stationary positive fractional volumes.
/// Faces are paired internal/periodic interfaces; stationary walls reflect normal velocity.
/// Moving geometry requires additional terms. This reference is separate from the app's air solver.
enum FractionalEulerFlux {
    enum Failure: Error { case invalidFace, invalidWall, invalidStep, unstableStep }
    struct Face {
        let a: Int
        let b: Int
        let normal: SIMD3<Double>  // Unit normal from a to b.
        let area: Double
    }
    struct Wall {
        let cell: Int
        let normal: SIMD3<Double>  // Unit normal outward from the gas.
        let area: Double
    }
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        /// Equal and opposite to the gas impulse, ordered like the supplied walls.
        let wallImpulses: [SIMD3<Double>]
    }
    private static let gamma = 1.4

    static func maximumStep(
        _ cells: [FractionalGasTransport.Cell], faces: [Face], walls: [Wall] = [], cfl: Double = 0.4
    ) throws -> Double {
        guard cfl.isFinite && cfl > 0 && cfl <= 0.5 else { throw Failure.invalidStep }
        _ = try FractionalGasTransport.advance(cells, newVolumes: cells.map(\.volume), transfers: [])
        var rates = [Double](repeating: 0, count: cells.count)
        for face in faces {
            guard cells.indices.contains(face.a), cells.indices.contains(face.b), face.a != face.b,
                face.area.isFinite && face.area >= 0,
                (0..<3).allSatisfy({ face.normal[$0].isFinite }),
                abs(simd_length_squared(face.normal) - 1) < 1e-12,
                cells[face.a].volume > 0 && cells[face.b].volume > 0
            else { throw Failure.invalidFace }
            let rate = face.area * signal(cells[face.a], cells[face.b], normal: face.normal)
            guard rate.isFinite else { throw Failure.invalidFace }
            rates[face.a] += rate
            rates[face.b] += rate
        }
        for wall in walls {
            guard cells.indices.contains(wall.cell), cells[wall.cell].volume > 0,
                wall.area.isFinite && wall.area >= 0,
                (0..<3).allSatisfy({ wall.normal[$0].isFinite }),
                abs(simd_length_squared(wall.normal) - 1) < 1e-12
            else { throw Failure.invalidWall }
            let rate = wall.area * signal(cells[wall.cell], cells[wall.cell], normal: wall.normal)
            guard rate.isFinite else { throw Failure.invalidWall }
            rates[wall.cell] += rate
        }
        return cells.indices.reduce(Double.infinity) { limit, n in
            rates[n] > 0 ? min(limit, cfl * cells[n].volume / rates[n]) : limit
        }
    }

    static func advance(
        _ cells: [FractionalGasTransport.Cell], faces: [Face], duration: Double, cfl: Double = 0.4
    ) throws -> [FractionalGasTransport.Cell] {
        try advanceWithWalls(cells, faces: faces, walls: [], duration: duration, cfl: cfl).cells
    }

    static func advanceWithWalls(
        _ cells: [FractionalGasTransport.Cell], faces: [Face], walls: [Wall], duration: Double,
        cfl: Double = 0.4
    ) throws -> Result {
        guard duration.isFinite && duration > 0 else { throw Failure.invalidStep }
        let limit = try maximumStep(cells, faces: faces, walls: walls, cfl: cfl)
        guard duration <= limit else { throw Failure.unstableStep }
        var amounts = cells.map(\.amount)
        for face in faces where face.area > 0 {
            let a = cells[face.a]
            let b = cells[face.b]
            let jump = b.amount / b.volume - a.amount / a.volume
            let flux =
                0.5 * (physical(a, normal: face.normal) + physical(b, normal: face.normal))
                - 0.5 * signal(a, b, normal: face.normal) * jump
            let packet = duration * face.area * flux
            amounts[face.a] -= packet
            amounts[face.b] += packet
        }
        var wallImpulses: [SIMD3<Double>] = []
        for wall in walls {
            if wall.area == 0 {
                wallImpulses.append(.zero)
                continue
            }
            let cell = cells[wall.cell]
            let density = cell.amount[0] / cell.volume
            let speed = simd_dot(cell.velocity, wall.normal)
            let waveSpeed = signal(cell, cell, normal: wall.normal)
            // Rusanov interface with a mirrored normal velocity: zero mass/energy flux,
            // normal momentum flux p + rho*u_n² + rho*s*u_n. Do not clip tensile traction.
            let traction = cell.pressure() + density * speed * speed + density * waveSpeed * speed
            guard traction.isFinite && traction >= 0 else { throw Failure.invalidWall }
            let impulse = duration * wall.area * traction * wall.normal
            amounts[wall.cell] -= SIMD8(0, impulse.x, impulse.y, impulse.z, 0, 0, 0, 0)
            wallImpulses.append(impulse)
        }
        let updated = cells.indices.map {
            FractionalGasTransport.Cell(volume: cells[$0].volume, amount: amounts[$0])
        }
        // Reject a nonphysical state transactionally, without density or pressure floors.
        return Result(
            cells: try FractionalGasTransport.advance(
                updated, newVolumes: updated.map(\.volume), transfers: []),
            wallImpulses: wallImpulses)
    }

    private static func signal(
        _ a: FractionalGasTransport.Cell, _ b: FractionalGasTransport.Cell, normal: SIMD3<Double>
    ) -> Double {
        [a, b].map {
            abs(simd_dot($0.velocity, normal)) + sqrt(gamma * $0.pressure() * $0.volume / $0.amount[0])
        }.max()!
    }

    private static func physical(
        _ cell: FractionalGasTransport.Cell, normal: SIMD3<Double>
    ) -> SIMD8<Double> {
        let state = cell.amount / cell.volume
        let speed = simd_dot(cell.velocity, normal)
        let pressure = cell.pressure()
        let momentum = SIMD3(state[1], state[2], state[3]) * speed + pressure * normal
        return SIMD8(
            state[0] * speed, momentum.x, momentum.y, momentum.z,
            (state[4] + pressure) * speed, 0, 0, 0)
    }
}
