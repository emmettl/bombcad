import Testing
import simd

@testable import BlastCore

@Suite("Stationary grouped reconstruction")
struct LimitedGroupedGasFluxTests {
    @Test("Full-rank nonuniform stencils reproduce affine primitive face values")
    func affine() throws {
        let centre = SIMD3<Double>(0.2, -0.1, 0.3)
        let centres =
            [centre]
            + [
                SIMD3<Double>(1, 0, 0), SIMD3(-0.7, 0, 0), SIMD3(0, 0.8, 0), SIMD3(0, -1.2, 0),
                SIMD3(0, 0, 0.6), SIMD3(0, 0, -0.9),
            ].map { centre + $0 }
        let gradient = SIMD3<Double>(2, -3, 4)
        let cells = centres.map { p in
            FractionalGasTransport.Cell(
                volume: 1, density: 2 + 0.01 * simd_dot(gradient, p),
                velocity: SIMD3(1, 2, 3) + 0.02 * simd_dot(gradient, p) * SIMD3(repeating: 1),
                pressure: 100000 + simd_dot(gradient, p))
        }
        let faces = (1..<centres.count).map { n in
            ConnectedGasGroups.Face(
                a: 0, b: n, area: 1,
                normal: simd_normalize(centres[n] - centre), centroid: (centre + centres[n]) / 2)
        }
        let g = try LimitedGroupedGasFlux.Geometry(centres: centres, faces: faces, boundaries: [])
        let traces = try g.traces(cells)
        for (n, face) in faces.enumerated() {
            let state = try #require(traces.faces[n].leftState)
            let value = simd_dot(gradient, face.centroid)
            #expect(abs(state.pressure() - 100000 - value) < 1e-9)
            #expect(abs(state.amount[0] - 2 - 0.01 * value) < 1e-12)
            #expect(simd_length(state.velocity - (SIMD3(1, 2, 3) + SIMD3(repeating: 0.02 * value))) < 1e-12)
        }
    }
    @Test("An interior affine pressure field produces its analytical momentum gradient")
    func affineFlux() throws {
        let n = 5
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n + j) * n + i }
        var centres: [SIMD3<Double>] = []
        var faces: [ConnectedGasGroups.Face] = []
        for k in 0..<n {
            for j in 0..<n {
                for i in 0..<n {
                    let p = SIMD3<Double>(Double(i), Double(j), Double(k))
                    centres.append(p)
                    for axis in 0..<3 {
                        var coordinates = [i, j, k]
                        coordinates[axis] += 1
                        if coordinates[axis] < n {
                            var normal = SIMD3<Double>.zero
                            normal[axis] = 1
                            faces.append(
                                .init(
                                    a: index(i, j, k),
                                    b: index(coordinates[0], coordinates[1], coordinates[2]),
                                    area: 1, normal: normal, centroid: p + normal / 2))
                        }
                    }
                }
            }
        }
        let gradient = SIMD3<Double>(20, -30, 40)
        let cells = centres.map {
            FractionalGasTransport.Cell(
                volume: 1, density: 1.225,
                pressure: 101325 + simd_dot(gradient, $0))
        }
        let geometry = try LimitedGroupedGasFlux.Geometry(centres: centres, faces: faces, boundaries: [])
        let traces = try geometry.traces(cells)
        let dt = 0.00001
        let updated = try FractionalEulerFlux.advance(cells, faces: traces.faces, duration: dt, cfl: 0.2)
        let middle = index(2, 2, 2)
        let change = updated[middle].amount - cells[middle].amount
        #expect(abs(change[0]) < 1e-12 && abs(change[4]) < 1e-9)
        #expect(simd_length(SIMD3(change[1], change[2], change[3]) + dt * gradient) < 1e-12)
    }
    @Test("Face and distant wall traces stay within positive one-ring primitive extrema")
    func bounded() throws {
        let centres = [
            SIMD3<Double>.zero, SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0),
            SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        ]
        let pressures = [2.0, 100000, 1, 4000, 0.1, 80000, 3]
        let densities = [0.01, 100, 0.001, 2, 0.0001, 10, 0.002]
        let cells = centres.indices.map {
            FractionalGasTransport.Cell(
                volume: 1, density: densities[$0],
                velocity: SIMD3(repeating: Double($0) - 3), pressure: pressures[$0])
        }
        let faces = (1..<centres.count).map { n in
            ConnectedGasGroups.Face(
                a: 0, b: n, area: 1,
                normal: centres[n], centroid: centres[n] / 2)
        }
        let geometry = try LimitedGroupedGasFlux.Geometry(
            centres: centres, faces: faces,
            boundaries: [.init(cell: 0, area: 1, normal: SIMD3(1, 0, 0), centroid: SIMD3(5, 3, -4))])
        let traces = try geometry.traces(cells)
        let states =
            traces.faces.flatMap { [$0.leftState!, $0.rightState!] } + traces.walls.map { $0.state! }
        for state in states {
            #expect(state.amount[0] >= densities.min()! && state.amount[0] <= densities.max()!)
            #expect(state.pressure() >= 0.099999999 && state.pressure() <= 100000.000001)
            #expect((0..<3).allSatisfy { state.velocity[$0] >= -3 && state.velocity[$0] <= 3 })
        }
    }
    @Test("Rank-deficient stencils fall back to constant positive traces")
    func deficient() throws {
        let cells = [100000.0, 1.0].map { FractionalGasTransport.Cell(volume: 1, density: 1, pressure: $0) }
        let g = try LimitedGroupedGasFlux.Geometry(
            centres: [.zero, SIMD3(1, 0, 0)],
            faces: [.init(a: 0, b: 1, area: 1, normal: SIMD3(1, 0, 0), centroid: SIMD3(0.5, 0, 0))],
            boundaries: [])
        let traces = try g.traces(cells)
        #expect(traces.faces[0].leftState!.pressure() == cells[0].pressure())
        #expect(traces.faces[0].rightState!.pressure() == cells[1].pressure())
    }
    @Test("Supplied wall traces control traction and CFL and reject invalid gas")
    func wallTrace() throws {
        let cells = [FractionalGasTransport.Cell(volume: 1, density: 1, pressure: 100000)]
        let state = FractionalGasTransport.Cell(volume: 1, density: 1, pressure: 200000)
        let normal = SIMD3<Double>(1, 0, 0)
        let wall = FractionalEulerFlux.Wall(cell: 0, normal: normal, area: 1, state: state)
        let limit = try FractionalEulerFlux.maximumStep(cells, faces: [], walls: [wall])
        let originalLimit = try FractionalEulerFlux.maximumStep(
            cells, faces: [],
            walls: [.init(cell: 0, normal: normal, area: 1)])
        #expect(limit < originalLimit)
        let dt = limit / 10
        let update = try FractionalEulerFlux.advanceWithWalls(cells, faces: [], walls: [wall], duration: dt)
        #expect(abs(update.wallImpulses[0].x - 200000 * dt) < 1e-10)
        #expect(update.wallWork[0] == 0 && update.cells[0].amount[4] == cells[0].amount[4])
        #expect(abs(update.cells[0].amount[1] + update.wallImpulses[0].x) < 1e-12)
        #expect(throws: FractionalGasTransport.Failure.self) {
            try FractionalEulerFlux.maximumStep(
                cells, faces: [],
                walls: [
                    .init(
                        cell: 0,
                        normal: normal, area: 1, state: .init(volume: 1, density: -1, pressure: 100000))
                ])
        }
    }
    @Test("Uniform clipped groups stay at rest through both limited stages")
    func resting() throws {
        let domain = try ExperimentalConnectedGasStudy.domain(cellSize: 0.2, rotation: 0.23)
        let plan = try ConnectedGasGroups.build(
            cells: domain.cells, centres: domain.centres,
            nominalVolume: 0.008, faces: domain.faces, boundaries: domain.boundaries)
        let cells = plan.groups.map(\.cell)
        let geometry = try LimitedGroupedGasFlux.Geometry(
            centres: plan.groups.map(\.centre),
            faces: plan.faces, boundaries: plan.boundaries)
        let traces = try geometry.traces(cells)
        let dt =
            try FractionalEulerFlux.maximumStep(cells, faces: traces.faces, walls: traces.walls, cfl: 0.2)
            * 0.9
        let update = try geometry.advance(cells, traces: traces, duration: dt, cfl: 0.2)
        #expect(
            update.cells.allSatisfy {
                simd_length($0.velocity) < 1e-10 && abs($0.pressure() / 101325 - 1) < 1e-12
            })
    }
    @Test("Limited pressure pulse closes extensive gas and wall budgets")
    func budgets() throws {
        let rows = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2], rotations: [0, 0.23],
            duration: 0.00005, targetPulseEnergy: 6400, volumeAverage: true, limited: true)
        for r in rows {
            #expect(r.transport == "limitedSSPRK2" && r.bodyImpulse.x > 0)
            #expect(abs(r.relativeMassChange) < 1e-12 && abs(r.relativeEnergyChange) < 1e-12)
            #expect(simd_length(r.momentumBudgetResidual) < 1e-10 && r.wallWork == 0)
        }
    }
}
