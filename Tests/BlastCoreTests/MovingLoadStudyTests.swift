import Testing
import simd

@testable import BlastCore

@Suite("Sustained moving pressure loads")
struct MovingLoadStudyTests {
    @Test("Nominal raw-cell closure resolves a tiny rotated corner while final groups remain conservative")
    func rotatedSliver() throws {
        let initial = try ExperimentalMovingGroupsStudy.body(angle: 0.23, time: 0)
        let position = SIMD3<Double>(1.0182583852462073, 1.028752795082069, 1.0402988819671721)
        let body = initial.translated(by: position - initial.position)
        let velocity = SIMD3<Double>(300, 100, -40)
        let d = try ExperimentalMovingGroupsStudy.domain(
            h: 0.05, angle: 0.23, start: 0, duration: 1.0587502003916538e-6,
            prescribedBody: body, prescribedVelocity: velocity, reconstruct: true, surfaceQuadrature: true)
        #expect(d.plan.maximumAreaResidual < 1e-8 && d.plan.maximumMomentResidual < 1e-8)
        #expect(d.plan.cells.allSatisfy { $0.volume >= 0.25 * 0.05 * 0.05 * 0.05 })
        let r = try MovingGroupedGasFlux.advance(
            d.plan, exterior: .init(volume: 1, density: 1.225, velocity: velocity, pressure: 101325),
            limited: true, timeIntegration: .heun)
        for cell in r.cells where cell.volume > 0 {
            #expect(abs(cell.pressure() / 101325 - 1) < 1e-9)
            #expect(simd_length(cell.velocity - velocity) < 1e-7)
        }
    }

    @Test("Clipped-cell initialization independently realizes matched pulse energy and gas inventory")
    func initialEnergy() throws {
        for h in [0.2, 0.1] {
            for angle in [0.0, 0.23] {
                let initial = try ExperimentalMovingLoadStudy.initialState(
                    h: h, angle: angle, targetEnergy: 6400)
                let mass = 1.225 * (8 - 0.8 * 0.8 * 0.8)
                let energy =
                    101325 * (8 - 0.8 * 0.8 * 0.8) / (1.4 - 1) + 0.5 * mass
                    * (300 * 300 + 100 * 100 + 40 * 40) + 6400
                #expect(abs(initial.mass - mass) < 1e-11)
                #expect(abs(initial.energy - energy) < 1e-7 && abs(initial.pulseEnergy - 6400) < 1e-7)
                #expect(initial.amplitude > 0 && initial.maximumPressure > 101325)
                #expect(initial.quadratureResidual < 1e-8)
                #expect(initial.cells.filter { $0.volume > 0 }.allSatisfy { $0.pressure() >= 101325 - 1e-8 })
            }
        }
    }

    @Test("Zero pulse recovers the existing uniform moving trajectory")
    func uniformReduction() throws {
        let loaded = try ExperimentalMovingLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23], cfls: [0.2],
            duration: 0.000016, targetPulseEnergy: 0)[0]
        let uniform = try ExperimentalMovingTrajectoryStudy.run(
            cellSizes: [0.2], rotations: [0.23], cfls: [0.2], duration: 0.000016,
            limited: true, secondOrder: true, surfaceQuadrature: true)[0]
        for (a, b) in zip(loaded.frames, uniform.frames) {
            #expect(
                a.steps == b.steps && a.dryToWetCells == b.dryToWetCells && a.wetToDryCells == b.wetToDryCells
            )
            #expect(simd_distance(a.bodyImpulse, b.bodyImpulse) < 1e-10)
            #expect(simd_distance(a.bodyAngularImpulse, b.bodyAngularImpulse) < 1e-10)
            #expect(a.maximumRelativeDensityDeparture < 1e-9 && a.maximumRelativePressureDeparture < 1e-9)
        }
    }

    @Test("Repeated varying pressure retains positive states and all gas/reservoir/body budgets")
    func evolvingPulse() throws {
        let rows = try ExperimentalMovingLoadStudy.run(
            cellSizes: [0.2], rotations: [0.23],
            cfls: [0.2, 0.1], duration: 0.00005)
        for r in rows {
            #expect(r.transport == "limitedHeun" && r.wallIntegration == "surfaceTimeQuadrature")
            #expect(abs(r.initialPulseEnergy - r.targetPulseEnergy) < 1e-7)
            #expect(r.frames.last!.steps > 4 && r.maximumMembers <= 64)
            #expect(r.minimumOldGroupFraction >= 0.25 && r.minimumFinalGroupFraction >= 0.25)
            let last = r.frames.last!
            #expect(last.maximumPerturbationSpeed > 0.01 && last.maximumRelativePressureDeparture > 0.1)
            #expect(simd_length(last.bodyImpulse) > 1e-3 && simd_length(last.bodyAngularImpulse) > 1e-4)
            #expect(
                last.dryToWetCells == r.referenceDryToWetCells
                    && last.wetToDryCells == r.referenceWetToDryCells)
            for f in r.frames {
                #expect(f.minimumPressure > 0 && f.minimumDensity > 0)
                #expect(abs(f.massBudgetResidual) < 1e-10 && simd_length(f.momentumBudgetResidual) < 1e-8)
                #expect(abs(f.energyBudgetResidual) < 1e-6 && abs(f.volumeResidual) < 1e-10)
                #expect(abs(f.impulseWorkResidual) < 1e-9)
            }
        }
    }

    @Test("Invalid pulse/grid/CFL and mismatched override inventories are rejected")
    func invalid() throws {
        for energy in [-1, Double.nan] {
            #expect(throws: ExperimentalMovingLoadStudy.Failure.invalidConfiguration) {
                try ExperimentalMovingLoadStudy.run(targetPulseEnergy: energy)
            }
        }
        #expect(throws: ExperimentalMovingLoadStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingLoadStudy.run(cellSizes: [0.03])
        }
        #expect(throws: ExperimentalMovingLoadStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingLoadStudy.run(cfls: [0.6])
        }
        #expect(throws: ExperimentalMovingTrajectoryStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingTrajectoryStudy.solve(
                h: 0.2, angle: 0, start: 0, duration: 1e-6,
                velocityScale: 100, cfl: 0.2, maximumStep: 1e-6,
                initialCells: [])
        }
        var initial = try ExperimentalMovingLoadStudy.initialState(h: 0.2, angle: 0, targetEnergy: 6400).cells
        initial[0] = .init(volume: initial[0].volume / 2, amount: initial[0].amount)
        #expect(throws: ExperimentalMovingTrajectoryStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingTrajectoryStudy.solve(
                h: 0.2, angle: 0, start: 0, duration: 1e-6,
                velocityScale: 100, cfl: 0.2, maximumStep: 1e-6,
                initialCells: initial)
        }
    }
}
