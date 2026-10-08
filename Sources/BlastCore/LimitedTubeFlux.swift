import simd

/// Minmod primitive reconstruction on ordered nonuniform tube cells with SSP two-stage time stepping.
/// Boundary cells retain zero slopes; this is an opt-in reference, not the app solver.
enum LimitedTubeFlux {
    static func faces(_ cells: [FractionalGasTransport.Cell], area: Double) -> [FractionalEulerFlux.Face] {
        let lengths = cells.map { $0.volume / area }
        let states = cells.map {
            SIMD8(
                $0.amount[0] / $0.volume, $0.velocity.x, $0.velocity.y, $0.velocity.z, $0.pressure(), 0, 0, 0)
        }
        var changes = [SIMD8<Double>](repeating: .zero, count: cells.count)
        if cells.count > 2 {
            for n in 1..<(cells.count - 1) {
                for component in 0..<5 {
                    let left = states[n][component] - states[n - 1][component]
                    let right = states[n + 1][component] - states[n][component]
                    if (left > 0 && right > 0) || (left < 0 && right < 0) {
                        let gradient = min(
                            abs(left) / ((lengths[n - 1] + lengths[n]) / 2),
                            abs(right) / ((lengths[n] + lengths[n + 1]) / 2))
                        let increment = min(gradient * lengths[n] / 2, abs(left), abs(right))
                        changes[n][component] = left > 0 ? increment : -increment
                    }
                }
            }
        }
        func trace(_ state: SIMD8<Double>) -> FractionalGasTransport.Cell {
            .init(
                volume: 1, density: state[0], velocity: SIMD3(state[1], state[2], state[3]),
                pressure: state[4])
        }
        return (0..<max(0, cells.count - 1)).map { n in
            .init(
                a: n, b: n + 1, normal: SIMD3(1, 0, 0), area: area,
                leftState: trace(states[n] + changes[n]), rightState: trace(states[n + 1] - changes[n + 1]))
        }
    }

    static func advance(
        _ old: [FractionalGasTransport.Cell], area: Double,
        walls: [FractionalEulerFlux.Wall], duration: Double, cfl: Double
    ) throws -> FractionalEulerFlux.Result {
        let first = try FractionalEulerFlux.advanceWithWalls(
            old, faces: faces(old, area: area),
            walls: walls, duration: duration, cfl: cfl)
        let second = try FractionalEulerFlux.advanceWithWalls(
            first.cells, faces: faces(first.cells, area: area),
            walls: walls, duration: duration, cfl: cfl)
        let cells = old.indices.map {
            FractionalGasTransport.Cell(
                volume: (old[$0].volume + second.cells[$0].volume) / 2,
                amount: (old[$0].amount + second.cells[$0].amount) / 2)
        }
        let checked = try FractionalGasTransport.advance(
            cells, newVolumes: cells.map(\.volume), transfers: [])
        return .init(
            cells: checked,
            wallImpulses: walls.indices.map { (first.wallImpulses[$0] + second.wallImpulses[$0]) / 2 },
            wallWork: walls.indices.map { (first.wallWork[$0] + second.wallWork[$0]) / 2 })
    }
}
