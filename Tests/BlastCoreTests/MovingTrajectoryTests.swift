import Testing
import simd

@testable import BlastCore

@Suite("Sustained prescribed moving gas")
struct MovingTrajectoryTests {
    @Test("Prescribed translation preserves the exact orientation and mechanical state")
    func poseCopy() throws {
        var body = try RigidBoxBody(
            mass: 2, size: SIMD3(repeating: 0.8),
            position: SIMD3(1, 1, 1),
            orientation: simd_quatd(angle: 0.23, axis: simd_normalize(SIMD3(1, 2, 3))),
            centreOfMass: SIMD3(0.1, 0, 0), inertia: SIMD3(repeating: 0.2))
        body.applyImpulse(SIMD3(2, -1, 0.5), at: body.worldPoint(SIMD3(0.2, 0, 0)))
        let displacement = SIMD3<Double>(0.04, 0.02, -0.01)
        let translated = body.translated(by: displacement)
        #expect(translated.orientation.vector == body.orientation.vector)
        #expect(translated.angularMomentum == body.angularMomentum)
        #expect(translated.linearVelocity == body.linearVelocity)
        #expect(translated.kineticEnergy == body.kineticEnergy)
        #expect(simd_distance(translated.worldPoint(.zero) - body.worldPoint(.zero), displacement) < 1e-14)
        #expect(body.position == SIMD3(1, 1, 1))
    }

    @Test("Continuation retains nonuniform accepted packets instead of reinitializing ambient gas")
    func continuedInventory() throws {
        let duration = 2e-6
        let first = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: 0, duration: duration)
        var old = first.old
        old[0] = .init(
            volume: old[0].volume, density: 1.225,
            velocity: ExperimentalMovingGroupsStudy.velocity, pressure: 125000)
        let initialized = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23,
            start: 0, duration: duration, previous: old, prescribedBody: first.body)
        let r = try MovingGroupedGasFlux.advance(initialized.plan, exterior: first.old[0])
        let next = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23,
            start: 0, duration: duration, previous: r.cells,
            prescribedBody: first.body.translated(by: duration * ExperimentalMovingGroupsStudy.velocity))
        for n in r.cells.indices {
            #expect(next.old[n].volume == r.cells[n].volume)
            #expect(next.old[n].amount == r.cells[n].amount)
        }
        #expect(next.old[0].pressure() > 110000)
        var incompatible = r.cells
        incompatible[0] = .init(volume: incompatible[0].volume * 0.9, amount: incompatible[0].amount)
        #expect(throws: ExperimentalMovingGroupsStudy.Failure.inconsistentInventory) {
            try ExperimentalMovingGroupsStudy.domain(
                h: 0.2, angle: 0.23, start: 0, duration: duration,
                previous: incompatible, prescribedBody: next.body)
        }
        #expect(throws: ExperimentalMovingGroupsStudy.Failure.inconsistentInventory) {
            try ExperimentalMovingGroupsStudy.domain(
                h: 0.2, angle: 0.23, start: 0, duration: duration,
                previous: [])
        }
    }

    @Test("Several cell crossings match an independent corner-containment oracle and cumulative budgets")
    func completeTrajectory() throws {
        let rows = try ExperimentalMovingTrajectoryStudy.run(cellSizes: [0.2])
        #expect(rows.count == 2)
        for r in rows {
            let last = r.frames.last!
            #expect(last.steps > 100)
            #expect(last.partitionChangedSteps > 0)
            #expect(last.dryToWetCells == r.referenceDryToWetCells)
            #expect(last.wetToDryCells == r.referenceWetToDryCells)
            #expect(last.dryToWetCells > 0 && last.wetToDryCells > 0)
            #expect(r.maximumMembers <= 64)
            #expect(r.minimumOldGroupFraction >= 0.25 && r.minimumFinalGroupFraction >= 0.25)
            #expect(simd_distance(r.displacement, r.velocity * r.duration) < 1e-12)
            for (n, f) in r.frames.enumerated() {
                #expect(f.time == Double(n + 1) * r.duration / 4)
                #expect(f.minimumPressure > 0)
                #expect(f.maximumRelativeDensityError < 1e-9)
                #expect(f.maximumRelativePressureError < 1e-9)
                #expect(f.maximumVelocityError < 1e-7)
                #expect(abs(f.massBudgetResidual) < 1e-10)
                #expect(simd_length(f.momentumBudgetResidual) < 1e-8)
                #expect(abs(f.energyBudgetResidual) < 1e-6)
                #expect(abs(f.volumeResidual) < 1e-10)
                #expect(abs(f.impulseWorkResidual) < 1e-9)
            }
        }
    }

    @Test("Original-speed crossing windows retry excessive steps and keep accepted time and pose")
    func ambientWindow() throws {
        let duration = 0.000064
        let rows = try ExperimentalMovingTrajectoryStudy.run(
            cellSizes: [0.2],
            duration: duration, velocityScale: 1, nearCrossing: true, maximumStep: 0.000032)
        for r in rows {
            let last = r.frames.last!
            #expect(last.rejectedSteps > 0)
            #expect(last.steps > 4)
            #expect(last.time == duration)
            #expect(last.dryToWetCells == r.referenceDryToWetCells)
            #expect(last.wetToDryCells == r.referenceWetToDryCells)
            #expect(simd_distance(r.displacement, duration * r.velocity) < 1e-12)
            #expect(last.maximumRelativePressureError < 1e-9)
            #expect(last.maximumVelocityError < 1e-7)
            #expect(abs(last.energyBudgetResidual) < 1e-6)
        }
    }

    @Test("Unsupported path extents, CFL values and trial steps are rejected")
    func invalidConfiguration() throws {
        #expect(throws: ExperimentalMovingTrajectoryStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingTrajectoryStudy.run(duration: 0.001)
        }
        #expect(throws: ExperimentalMovingTrajectoryStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingTrajectoryStudy.run(cfls: [0.6])
        }
        #expect(throws: ExperimentalMovingTrajectoryStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingTrajectoryStudy.run(maximumStep: 0)
        }
    }

    @Test("A roundoff contact has consistent dry volume and face support")
    func roundoffContact() throws {
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 1),
            position: SIMD3(0.5 + Double.ulpOfOne, 0.5, 0.5))
        let geometry = FractionalBoxGeometry(body)
        #expect(geometry.gasVolume(lower: .zero, cellSize: 1) == 0)
        #expect(geometry.gasQuadrature(lower: .zero, cellSize: 1).isEmpty)
        #expect(geometry.openFacePatches(lower: .zero, cellSize: 1).allSatisfy { $0.area == 0 })
    }
}
