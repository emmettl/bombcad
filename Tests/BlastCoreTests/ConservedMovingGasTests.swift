import Testing
import simd

@testable import BlastCore

@Suite("Conserved quadratic moving gas")
struct ConservedMovingGasTests {
    @Test("Both endpoint geometries preserve comoving uniform gas through sampled Euler and Heun updates")
    func uniform() throws {
        let velocity = SIMD3<Double>(300, 100, -40)
        for angle in [0.23, 0.4] {
            let domain = try ExperimentalMovingGroupsStudy.domain(
                h: 0.2, angle: angle, start: 0, duration: 2e-7, prescribedVelocity: velocity,
                reconstruct: true, surfaceQuadrature: true, conservedQuadratic: true)
            #expect(domain.plan.oldConservedGeometry != nil && domain.plan.finalConservedGeometry != nil)
            for integration in [MovingGroupedGasFlux.TimeIntegration.euler, .heun] {
                let result = try MovingGroupedGasFlux.advance(
                    domain.plan,
                    exterior: .init(volume: 1, density: 1.225, velocity: velocity, pressure: 101325),
                    limited: true, timeIntegration: integration, conservedQuadratic: true)
                for cell in result.cells where cell.volume > 0 {
                    #expect(abs(cell.amount[0] / cell.volume / 1.225 - 1) < 1e-9)
                    #expect(abs(cell.pressure() / 101325 - 1) < 1e-9)
                    #expect(simd_distance(cell.velocity, velocity) < 1e-7)
                }
                let before = domain.old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                let after = result.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                let impulse = result.wallImpulses.reduce(SIMD3<Double>.zero, +)
                let work = result.wallWork.reduce(0, +)
                let residual =
                    after - before - result.reservoirExchange
                    + SIMD8<Double>(0, impulse.x, impulse.y, impulse.z, work, 0, 0, 0)
                #expect(abs(residual[0]) < 1e-10)
                #expect(simd_length(SIMD3(residual[1], residual[2], residual[3])) < 1e-8)
                #expect(abs(residual[4]) < 1e-6)
            }
        }
    }

    @Test("Repeated evolving pressure closes all gas/reservoir/body budgets with positive accepted states")
    func pulse() throws {
        let row = try ExperimentalMovingLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23], cfls: [0.2], duration: 0.00002,
            conservedQuadratic: true)[0]
        #expect(row.transport == "conservedQuadraticHeun")
        #expect(abs(row.initialPulseEnergy - 6400) < 1e-7)
        #expect(row.frames.last!.steps >= 4)
        #expect(simd_length(row.frames.last!.bodyImpulse) > 1e-3)
        #expect(row.frames.last!.maximumPerturbationSpeed > 0.01)
        for frame in row.frames {
            #expect(frame.minimumDensity > 0 && frame.minimumPressure > 0)
            #expect(abs(frame.massBudgetResidual) < 1e-10)
            #expect(simd_length(frame.momentumBudgetResidual) < 1e-8)
            #expect(abs(frame.energyBudgetResidual) < 1e-6)
            #expect(abs(frame.impulseWorkResidual) < 1e-9)
        }
    }

    @Test("A requested quadratic stage refuses absent endpoint moments and unsupported constant-state mode")
    func missingGeometry() throws {
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: 0, duration: 2e-7, reconstruct: true)
        let exterior = FractionalGasTransport.Cell(volume: 1, density: 1.225, pressure: 101325)
        #expect(throws: MovingConnectedGasGroups.Failure.invalidGeometry) {
            try MovingGroupedGasFlux.advance(
                domain.plan, exterior: exterior, limited: true, conservedQuadratic: true)
        }
        #expect(throws: ExperimentalMovingGroupsStudy.Failure.inconsistentInventory) {
            try ExperimentalMovingGroupsStudy.domain(
                h: 0.2, angle: 0, start: 0, duration: 1e-7, conservedQuadratic: true)
        }
    }

    @Test(
        "Strong normal-shock reflection closes stationary budgets and pressure history improves under refinement"
    )
    func reflection() throws {
        let rows = try ExperimentalWallReflectionStudy.run(
            cellLengths: [0.1, 0.05], cfls: [0.2], machNumbers: [2], limited: true,
            conservedQuadratic: true)
        #expect(rows.count == 2)
        #expect(rows[1].relativePressureHistoryL1 < rows[0].relativePressureHistoryL1)
        for row in rows {
            #expect(row.transport == "conservedQuadraticSSPRK2")
            #expect(abs(row.relativeMassChange) < 1e-10 && abs(row.relativeEnergyChange) < 1e-10)
            #expect(simd_length(row.momentumBudgetResidual) < 1e-8)
            #expect(row.frames.last!.exactExcessImpulse > 0)
        }
    }

    @Test(
        "Exact moving quadratic-density transport retains constant pressure/velocity and improves under refinement"
    )
    func entropy() throws {
        let velocity = SIMD3<Double>(300, 100, -40)
        let reference = try AdvectedQuadraticGas(velocity: velocity)
        let rows = try [0.2, 0.1].map { h in
            try ExperimentalMovingTrajectoryStudy.solve(
                h: h, angle: 0.23, start: 0, duration: 0.00008, velocityScale: 100,
                cfl: 0.2, maximumStep: h * 0.00008, reference: reference, limited: true,
                secondOrder: true, surfaceQuadrature: true, conservedQuadratic: true)
        }
        #expect(
            rows[1].frames.last!.transport!.relativeDensityL1
                < rows[0].frames.last!.transport!.relativeDensityL1)
        for row in rows {
            #expect(row.reconstruction == "conservedQuadratic")
            for frame in row.frames {
                #expect(frame.maximumRelativePressureError < 1e-8)
                #expect(frame.maximumVelocityError < 1e-6)
                #expect(frame.transport!.minimumDensity > 0)
                #expect(abs(frame.massBudgetResidual) < 1e-10 && abs(frame.energyBudgetResidual) < 1e-6)
                #expect(simd_length(frame.momentumBudgetResidual) < 1e-8)
            }
        }
    }

    @Test(
        "A moving 3D piston hit by a Mach-2 shock preserves work/budgets and improves exact wall history with refinement"
    )
    func movingShock() throws {
        let velocity = SIMD3<Double>(-20, 0, 0)
        let reference = try MovingShockReflection(mach: 2, velocity: velocity.x)
        let s = reference.stationary
        let inflow = FractionalGasTransport.Cell(
            volume: 1, density: s.incidentDensity,
            velocity: SIMD3(velocity.x - s.incidentVelocity, 0, 0), pressure: s.incidentPressure)
        var errors: [Double] = []
        for h in [0.2, 0.1] {
            let n = Int((2 / h).rounded())
            var body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 4), position: SIMD3(4, 1, 1))
            var cells: [FractionalGasTransport.Cell] = []
            for _ in 0..<(n * n) {
                for x in 0..<n {
                    cells.append(
                        try reference.cell(
                            lower: Double(x) * h, upper: Double(x + 1) * h, time: 0, area: h * h))
                }
            }
            let before = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            var elapsed = 0.0
            var hint = h * 8e-5
            var reservoir = SIMD8<Double>.zero
            var bodyImpulse = SIMD3<Double>.zero
            var work = 0.0
            var historyError = 0.0
            var steps = 0
            for fraction in [0.8, 1.0, 1.2, 1.4] {
                let target = fraction * s.arrivalTime
                while elapsed < target {
                    var dt = min(hint, target - elapsed)
                    var accepted: MovingGroupedGasFlux.Result?
                    for _ in 0..<24 {
                        let plan = try ExperimentalMovingGroupsStudy.domain(
                            h: h, angle: 0, start: 0, duration: dt, previous: cells,
                            prescribedBody: body, prescribedVelocity: velocity,
                            reconstruct: true, surfaceQuadrature: true, conservedQuadratic: true,
                            slipSideWalls: true
                        ).plan
                        do {
                            accepted = try MovingGroupedGasFlux.advance(
                                plan, exterior: inflow, cfl: 0.2, limited: true,
                                timeIntegration: .heun, conservedQuadratic: true)
                            break
                        } catch FractionalEulerFlux.Failure.unstableStep {
                            dt /= 2
                        } catch FractionalGasTransport.Failure.invalidState { dt /= 2 }
                    }
                    let result = try #require(accepted)
                    let impulse = result.wallImpulses.reduce(SIMD3<Double>.zero, +)
                    let intervalWork = result.wallWork.reduce(0, +)
                    let exact =
                        try reference.wallImpulse(time: elapsed + dt, area: 4)
                        - reference.wallImpulse(time: elapsed, area: 4)
                    historyError += abs(impulse.x - exact)
                    bodyImpulse += impulse
                    work += intervalWork
                    reservoir += result.reservoirExchange
                    cells = result.cells
                    body = body.translated(by: dt * velocity)
                    elapsed += dt
                    hint = min(h * 8e-5, 0.9 * result.maximumStep)
                    steps += 1
                    #expect(steps < 10000)
                    #expect(abs(intervalWork - velocity.x * impulse.x) < 1e-8)
                }
            }
            let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let residual =
                after - before - reservoir
                + SIMD8(0, bodyImpulse.x, bodyImpulse.y, bodyImpulse.z, work, 0, 0, 0)
            #expect(abs(residual[0]) < 1e-8 && abs(residual[4]) < 1e-5)
            #expect(simd_length(SIMD3(residual[1], residual[2], residual[3])) < 1e-6)
            #expect(cells.filter { $0.volume > 0 }.allSatisfy { $0.pressure() > 0 })
            let exactExcess = try reference.wallImpulse(time: elapsed, area: 4) - 4 * s.pressure * elapsed
            errors.append(historyError / exactExcess)
        }
        #expect(errors[1] < errors[0])
    }
}
