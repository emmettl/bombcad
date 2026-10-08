import simd

/// Ideal-gas Rusanov flux for positive fractional volumes, with optional supplied face traces.
/// Faces are paired internal/periodic interfaces; planar walls use exact local wall pressure.
/// Constant-area planar walls may move within an interval of fixed cell topology.
/// This reference is separate from the app's air solver.
enum FractionalEulerFlux {
    enum Failure: Error { case invalidFace, invalidWall, invalidStep, unstableStep }
    struct Face {
        let a: Int
        let b: Int
        let normal: SIMD3<Double>  // Unit normal from a to b.
        let area: Double
        let leftState: FractionalGasTransport.Cell?
        let rightState: FractionalGasTransport.Cell?
        init(
            a: Int, b: Int, normal: SIMD3<Double>, area: Double,
            leftState: FractionalGasTransport.Cell? = nil, rightState: FractionalGasTransport.Cell? = nil
        ) {
            self.a = a
            self.b = b
            self.normal = normal
            self.area = area
            self.leftState = leftState
            self.rightState = rightState
        }
    }
    struct Wall {
        let cell: Int
        let normal: SIMD3<Double>  // Unit normal outward from the gas.
        let area: Double
        let velocity: SIMD3<Double>
        let state: FractionalGasTransport.Cell?
        init(
            cell: Int, normal: SIMD3<Double>, area: Double, velocity: SIMD3<Double> = .zero,
            state: FractionalGasTransport.Cell? = nil
        ) {
            self.cell = cell
            self.normal = normal
            self.area = area
            self.velocity = velocity
            self.state = state
        }
    }
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        /// Equal and opposite to the gas impulse, ordered like the supplied walls.
        let wallImpulses: [SIMD3<Double>]
        /// Work delivered to each prescribed wall, opposite to gas energy change.
        let wallWork: [Double]
    }
    private static let gamma = 1.4

    static func maximumStep(
        _ cells: [FractionalGasTransport.Cell], faces: [Face], walls: [Wall] = [], cfl: Double = 0.4
    ) throws -> Double {
        guard cfl.isFinite && cfl > 0 && cfl <= 0.5 else { throw Failure.invalidStep }
        _ = try FractionalGasTransport.advance(cells, newVolumes: cells.map(\.volume), transfers: [])
        var rates = [Double](repeating: 0, count: cells.count)
        var volumeRates = [Double](repeating: 0, count: cells.count)
        for face in faces {
            guard cells.indices.contains(face.a), cells.indices.contains(face.b), face.a != face.b,
                face.area.isFinite && face.area >= 0,
                (0..<3).allSatisfy({ face.normal[$0].isFinite }),
                abs(simd_length_squared(face.normal) - 1) < 1e-12,
                cells[face.a].volume > 0 && cells[face.b].volume > 0
            else { throw Failure.invalidFace }
            let a = face.leftState ?? cells[face.a]
            let b = face.rightState ?? cells[face.b]
            guard a.volume > 0 && b.volume > 0 else { throw Failure.invalidFace }
            if face.leftState != nil || face.rightState != nil {
                _ = try FractionalGasTransport.advance(
                    [a, b], newVolumes: [a.volume, b.volume], transfers: [])
            }
            let rate = face.area * signal(a, b, normal: face.normal)
            guard rate.isFinite else { throw Failure.invalidFace }
            rates[face.a] += rate
            rates[face.b] += rate
        }
        for wall in walls {
            guard cells.indices.contains(wall.cell), cells[wall.cell].volume > 0,
                wall.area.isFinite && wall.area >= 0,
                (0..<3).allSatisfy({ wall.normal[$0].isFinite }),
                (0..<3).allSatisfy({ wall.velocity[$0].isFinite }),
                abs(simd_length_squared(wall.normal) - 1) < 1e-12
            else { throw Failure.invalidWall }
            let trace = wall.state ?? cells[wall.cell]
            guard trace.volume > 0 else { throw Failure.invalidWall }
            if wall.state != nil {
                _ = try FractionalGasTransport.advance([trace], newVolumes: [trace.volume], transfers: [])
            }
            let normalSpeed = simd_dot(wall.velocity, wall.normal)
            let rate =
                try wall.area * (wallState(trace, wall: wall).signalSpeed + abs(normalSpeed))
            guard rate.isFinite else { throw Failure.invalidWall }
            rates[wall.cell] += rate
            volumeRates[wall.cell] += wall.area * normalSpeed
        }
        return cells.indices.reduce(Double.infinity) { limit, n in
            let acoustic = rates[n] > 0 ? cfl * cells[n].volume / rates[n] : .infinity
            let geometric = volumeRates[n] < 0 ? cfl * cells[n].volume / -volumeRates[n] : .infinity
            return min(limit, acoustic, geometric)
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
            let a = face.leftState ?? cells[face.a]
            let b = face.rightState ?? cells[face.b]
            let jump = b.amount / b.volume - a.amount / a.volume
            let flux =
                0.5 * (physical(a, normal: face.normal) + physical(b, normal: face.normal))
                - 0.5 * signal(a, b, normal: face.normal) * jump
            let packet = duration * face.area * flux
            amounts[face.a] -= packet
            amounts[face.b] += packet
        }
        var wallImpulses: [SIMD3<Double>] = []
        var wallWork: [Double] = []
        var volumes = cells.map(\.volume)
        for wall in walls {
            if wall.area == 0 {
                wallImpulses.append(.zero)
                wallWork.append(0)
                continue
            }
            let cell = wall.state ?? cells[wall.cell]
            let traction = try wallState(cell, wall: wall).pressure
            let impulse = duration * wall.area * traction * wall.normal
            let work = simd_dot(impulse, wall.velocity)
            volumes[wall.cell] += duration * wall.area * simd_dot(wall.velocity, wall.normal)
            amounts[wall.cell] -= SIMD8(0, impulse.x, impulse.y, impulse.z, work, 0, 0, 0)
            wallImpulses.append(impulse)
            wallWork.append(work)
        }
        let updated = cells.indices.map {
            FractionalGasTransport.Cell(volume: volumes[$0], amount: amounts[$0])
        }
        // Reject a nonphysical state transactionally, without density or pressure floors.
        return Result(
            cells: try FractionalGasTransport.advance(
                updated, newVolumes: updated.map(\.volume), transfers: []),
            wallImpulses: wallImpulses, wallWork: wallWork)
    }

    private static func wallState(
        _ cell: FractionalGasTransport.Cell, wall: Wall
    ) throws -> IdealGasWallRiemann.Result {
        try IdealGasWallRiemann.solve(
            density: cell.amount[0] / cell.volume, pressure: cell.pressure(),
            normalVelocity: simd_dot(cell.velocity - wall.velocity, wall.normal))
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
