import Testing
import simd

@testable import BlastCore

@Suite("Moving gas time integration")
struct MovingTimeIntegrationTests {
    // A local piston control volume isolates time error from clipping, changing groups
    // and spatial reconstruction. Its single wall changes V at a constant speed.
    private func piston(
        _ cell: FractionalGasTransport.Cell, speed: Double, duration: Double
    ) -> MovingConnectedGasGroups.Plan {
        let volume = cell.volume + speed * duration
        return .init(
            members: [[0]], cellToGroup: [0], cells: [cell], finalVolumes: [volume],
            memberFinalVolumes: [volume], faces: [],
            boundaries: [
                .init(
                    geometry: .init(
                        cell: 0, area: 1, normal: SIMD3(1, 0, 0),
                        centroid: .zero, owner: 1), meanTime: duration / 2)
            ],
            duration: duration, velocity: SIMD3(speed, 0, 0), oldCentres: nil,
            finalCentres: nil, memberFinalCentres: nil, finalFaces: nil,
            maximumAreaResidual: 0, maximumMomentResidual: 0, maximumVolumeResidual: 0)
    }

    @Test("Expanding-volume Heun update converges at second order with paired wall work")
    func temporalConvergence() throws {
        let initial = FractionalGasTransport.Cell(volume: 1, density: 1, pressure: 1)
        let speed = 0.4
        let duration = 0.2
        // Independent RK4 integration of the local pressure ODE, with the actual
        // V(t). This reference never calls the grouped or Euler time-step routines.
        func derivative(_ amount: SIMD8<Double>, _ time: Double) throws -> SIMD8<Double> {
            let cell = FractionalGasTransport.Cell(volume: 1 + speed * time, amount: amount)
            let wall = try IdealGasWallRiemann.solve(
                density: amount[0] / cell.volume, pressure: cell.pressure(),
                normalVelocity: cell.velocity.x - speed)
            return SIMD8(0, -wall.pressure, 0, 0, -speed * wall.pressure, 0, 0, 0)
        }
        var reference = initial.amount
        let fineStep = duration / 2048
        for n in 0..<2048 {
            let t = Double(n) * fineStep
            let a = try derivative(reference, t)
            let b = try derivative(reference + fineStep / 2 * a, t + fineStep / 2)
            let c = try derivative(reference + fineStep / 2 * b, t + fineStep / 2)
            let d = try derivative(reference + fineStep * c, t + fineStep)
            reference += fineStep / 6 * (a + 2 * b + 2 * c + d)
        }
        for method in [MovingGroupedGasFlux.TimeIntegration.euler, .heun] {
            var errors: [Double] = []
            for count in [4, 8, 16, 32] {
                var cell = initial
                var impulse = SIMD3<Double>.zero
                var work = 0.0
                for _ in 0..<count {
                    let r = try MovingGroupedGasFlux.advance(
                        piston(cell, speed: speed, duration: duration / Double(count)),
                        exterior: initial, timeIntegration: method)
                    cell = r.cells[0]
                    impulse += r.wallImpulses[0]
                    work += r.wallWork[0]
                    #expect(r.reservoirExchange == .zero && cell.pressure() > 0)
                }
                #expect(abs(cell.volume - (1 + speed * duration)) < 1e-13)
                #expect(abs(cell.amount[0] - initial.amount[0]) < 1e-13)
                #expect(abs(cell.amount[1] + impulse.x) < 1e-13)
                #expect(abs(cell.amount[4] - initial.amount[4] + work) < 1e-13)
                #expect(abs(work - speed * impulse.x) < 1e-13)
                errors.append(abs(cell.amount[1] - reference[1]))
            }
            for n in 0..<3 {
                let rate = log2(errors[n] / errors[n + 1])
                #expect(method == .heun ? rate > 1.9 && rate < 2.1 : rate > 0.9 && rate < 1.1)
            }
        }
    }

    @Test("Both stages enforce CFL before accepting a contracted endpoint")
    func secondStageCFL() throws {
        let initial = FractionalGasTransport.Cell(
            volume: 1, density: 1, velocity: SIMD3(-1, 0, 0), pressure: 1)
        let wall = FractionalEulerFlux.Wall(
            cell: 0, normal: SIMD3(1, 0, 0), area: 1,
            velocity: SIMD3(-1, 0, 0))
        let dt = try 0.99 * FractionalEulerFlux.maximumStep([initial], faces: [], walls: [wall])
        let first = try FractionalEulerFlux.advanceWithWalls(
            [initial], faces: [], walls: [wall], duration: dt)
        #expect(dt > (try FractionalEulerFlux.maximumStep(first.cells, faces: [], walls: [wall])))
        #expect(throws: FractionalEulerFlux.Failure.unstableStep) {
            try MovingGroupedGasFlux.advance(
                piston(initial, speed: -1, duration: dt), exterior: initial,
                cfl: 0.4, timeIntegration: .heun)
        }
        #expect(initial.volume == 1 && initial.amount[0] == 1 && initial.amount[1] == -1)
    }

    @Test("Interval reservoir averages are sampled once; endpoint ghosts belong to stage two")
    func reservoirStages() throws {
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: 0.4, angle: 0.23, start: 0, duration: 0.000002, reconstruct: true)
        let p = domain.plan
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: p.velocity,
            pressure: 101325)
        var supplied = 0
        var oldGhosts = 0
        var finalGhosts = 0
        let r = try MovingGroupedGasFlux.advance(
            p,
            exteriorAt: { _ in
                supplied += 1
                return exterior
            }, limited: true,
            reconstructionExteriorAt: { _, _ in
                oldGhosts += 1
                return exterior
            },
            reconstructionExteriorAtEnd: { _, _ in
                finalGhosts += 1
                return exterior
            },
            timeIntegration: .heun)
        let count = p.boundaries.filter { $0.geometry.owner == 0 }.count
        #expect(supplied == count && oldGhosts == count && finalGhosts == count)
        for cell in r.cells where cell.volume > 0 {
            #expect(abs(cell.amount[0] / cell.volume / 1.225 - 1) < 1e-10)
            #expect(abs(cell.pressure() / 101325 - 1) < 1e-10)
            #expect(simd_length(cell.velocity - p.velocity) < 1e-8)
        }
        let before = p.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = r.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let impulse = r.wallImpulses.reduce(SIMD3<Double>.zero, +)
        let residual = after - before - r.reservoirExchange
        #expect(abs(residual[0]) < 1e-11)
        #expect(simd_length(SIMD3(residual[1], residual[2], residual[3]) + impulse) < 1e-8)
        #expect(abs(residual[4] + r.wallWork.reduce(0, +)) < 1e-6)
    }

    @Test("Two-stage uniform gas survives original-speed wet/dry regrouping")
    func uniformCrossing() throws {
        for limited in [false, true] {
            let rows = try ExperimentalMovingTrajectoryStudy.run(
                cellSizes: [0.2], duration: 0.000064, velocityScale: 1, nearCrossing: true,
                limited: limited, secondOrder: true)
            for r in rows {
                let f = r.frames.last!
                #expect(r.timeIntegration == "heun")
                #expect(
                    f.dryToWetCells == r.referenceDryToWetCells && f.wetToDryCells == r.referenceWetToDryCells
                )
                #expect(f.maximumRelativeDensityError < 1e-9 && f.maximumRelativePressureError < 1e-9)
                #expect(f.maximumVelocityError < 1e-7 && abs(f.energyBudgetResidual) < 1e-6)
            }
        }
    }
}
