import Testing
import simd

@testable import BlastCore

@Suite("Analytical nonuniform moving-gas transport")
struct MovingEntropyTests {
    private let velocity = SIMD3<Double>(300, 100, -40)

    @Test("Full and half-fluid cells recover exact quadratic density averages and uniform p/u")
    func cellAverages() throws {
        let reference = try AdvectedQuadraticGas(velocity: velocity)
        let time = 0.0004
        let full = FractionalBoxGeometry(
            try RigidBoxBody(
                mass: 1,
                size: SIMD3(repeating: 1), position: SIMD3(repeating: 10)))
        let half = FractionalBoxGeometry(
            try RigidBoxBody(
                mass: 1,
                size: SIMD3(repeating: 2), position: SIMD3(-0.5, 0.5, 0.5)))
        for (geometry, volume, midpoint, variance) in [
            (full, 1.0, 0.5, 1.0 / 12), (half, 0.5, 0.75, 1.0 / 48),
        ] {
            let cell = try reference.cell(
                geometry: geometry, lower: .zero, cellSize: 1,
                time: time, volume: volume)
            let offset = midpoint - velocity.x * time - 1
            let expected = 1.225 * (1 + 0.2 * (offset * offset + variance))
            #expect(abs(cell.amount[0] / volume / expected - 1) < 1e-13)
            #expect(abs(cell.pressure() / 101325 - 1) < 1e-13)
            #expect(simd_distance(cell.velocity, velocity) < 1e-12)
        }
    }

    @Test("Exterior state quadrature matches independent spatial/time Gauss samples")
    func exteriorAverage() throws {
        let reference = try AdvectedQuadraticGas(velocity: velocity)
        let h = 0.2
        let start = 0.0001
        let duration = 0.00002
        for normal in [SIMD3<Double>(-1, 0, 0), SIMD3<Double>(0, 1, 0)] {
            let centre = SIMD3<Double>(0.2, 0.4, 0.6)
            let b = MovingConnectedGasGroups.Boundary(
                geometry: .init(
                    cell: 0, area: h * h,
                    normal: normal, centroid: centre), meanTime: duration / 2)
            let trace = try reference.exterior(boundary: b, cellSize: h, start: start, duration: duration)
            var expected = 0.0
            for timeSign in [-1.0, 1.0] {
                for spaceSign in [-1.0, 1.0] {
                    let time = start + duration / 2 + timeSign * duration / (2 * sqrt(3.0))
                    var point = centre
                    if normal.x == 0 { point.x += spaceSign * h / (2 * sqrt(3.0)) }
                    expected += reference.density(at: point, time: time) / 4
                }
            }
            #expect(abs(trace.amount[0] / expected - 1) < 1e-14)
        }
    }

    @Test(
        "Closed-form whole-domain mass agrees with rotated clipped-cell quadrature and exact advection gain")
    func domainMass() throws {
        let reference = try AdvectedQuadraticGas(velocity: velocity)
        let time = 0.0008
        let h = 0.4
        for angle in [0.0, 0.23] {
            let initial = try ExperimentalMovingGroupsStudy.body(angle: angle, time: 0)
            let geometry = FractionalBoxGeometry(initial.translated(by: velocity * time))
            var mass = 0.0
            for z in 0..<5 {
                for y in 0..<5 {
                    for x in 0..<5 {
                        let lower = h * SIMD3(Double(x), Double(y), Double(z))
                        let cell = try reference.cell(
                            geometry: geometry, lower: lower, cellSize: h,
                            time: time, volume: geometry.gasVolume(lower: lower, cellSize: h))
                        mass += cell.amount[0]
                    }
                }
            }
            #expect(abs(mass - reference.domainMass(initialBody: initial, time: time)) < 1e-12)
            let gain =
                reference.domainMass(initialBody: initial, time: time)
                - reference.domainMass(initialBody: initial, time: 0)
            #expect(abs(gain - 8 * 1.225 * 0.2 * pow(velocity.x * time, 2)) < 1e-13)
        }
    }

    @Test("Nonuniform moving transport improves with grid refinement while retaining p/u and budgets")
    func convergence() throws {
        let rows = try ExperimentalMovingEntropyStudy.run(cellSizes: [0.4, 0.2], rotations: [0], cfls: [0.2])
        #expect(rows.count == 2)
        let coarse = rows[0].frames.last!.transport!.relativeDensityL1
        let fine = rows[1].frames.last!.transport!.relativeDensityL1
        #expect(fine > 0 && fine < coarse)
        for r in rows {
            let last = r.frames.last!
            #expect(r.densityProfile == "quadratic-advection")
            #expect(last.dryToWetCells == r.referenceDryToWetCells)
            #expect(last.wetToDryCells == r.referenceWetToDryCells)
            for f in r.frames {
                let t = f.transport!
                #expect(t.minimumDensity > 0)
                #expect(abs(t.referenceQuadratureMassResidual) < 1e-11)
                #expect(f.maximumRelativePressureError < 1e-9)
                #expect(f.maximumVelocityError < 1e-7)
                #expect(abs(f.massBudgetResidual) < 1e-10)
                #expect(simd_length(f.momentumBudgetResidual) < 1e-8)
                #expect(abs(f.energyBudgetResidual) < 1e-6)
                #expect(abs(f.impulseWorkResidual) < 1e-9)
            }
        }
    }

    @Test("Invalid profiles, inconsistent frame velocities and nonphysical boundary traces fail")
    func rejectedInputs() throws {
        #expect(throws: AdvectedQuadraticGas.Failure.invalidDefinition) {
            try AdvectedQuadraticGas(velocity: velocity, amplitude: 0)
        }
        let reference = try AdvectedQuadraticGas(velocity: .zero)
        #expect(throws: ExperimentalMovingTrajectoryStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingTrajectoryStudy.solve(
                h: 0.4, angle: 0, start: 0, duration: 0.0008,
                velocityScale: 100, cfl: 0.2, maximumStep: 0.000008, reference: reference)
        }
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0,
            start: 0, duration: 0.000002)
        let before = domain.plan.cells.map(\.amount)
        #expect(throws: MovingConnectedGasGroups.Failure.invalidState) {
            try MovingGroupedGasFlux.advance(
                domain.plan, exteriorAt: { _ in .init(volume: 0, amount: .zero) })
        }
        #expect(domain.plan.cells.map(\.amount) == before)
    }
}
