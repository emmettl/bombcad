import Testing
import simd

@testable import BlastCore

@Suite("Moving connected gas inventories")
struct MovingConnectedGasGroupsTests {
    private func slabPlan(maximumMembers: Int = 64, final: [Double] = [0, 1]) throws
        -> MovingConnectedGasGroups.Plan
    {
        // Mean geometry partitions a unit cube into two half-width slabs. Old/final
        // inventories exchange sides; neither half has both endpoint capacities alone.
        let centres = [SIMD3<Double>(0.25, 0.5, 0.5), SIMD3<Double>(0.75, 0.5, 0.5)]
        var boundaries: [MovingConnectedGasGroups.Boundary] = []
        for cell in 0..<2 {
            let sign = cell == 0 ? -1.0 : 1.0
            boundaries.append(
                .init(
                    geometry: .init(
                        cell: cell, area: 1,
                        normal: SIMD3(sign, 0, 0), centroid: SIMD3(Double(cell), 0.5, 0.5), owner: 1),
                    meanTime: 0.5))
            for axis in 1..<3 {
                for side in [-1.0, 1.0] {
                    var normal = SIMD3<Double>.zero
                    normal[axis] = side
                    boundaries.append(
                        .init(
                            geometry: .init(
                                cell: cell, area: 0.5, normal: normal,
                                centroid: centres[cell] + 0.5 * normal, owner: 1), meanTime: 0.5))
                }
            }
        }
        return try MovingConnectedGasGroups.build(
            old: [
                .init(volume: 1, density: 2, velocity: SIMD3(1, 0, 0), pressure: 101325),
                .init(volume: 0, amount: .zero),
            ], finalVolumes: final, meanVolumes: [0.5, 0.5],
            centres: centres, nominalVolume: 1,
            faces: [.init(a: 0, b: 1, area: 1, normal: SIMD3(1, 0, 0), centroid: SIMD3(repeating: 0.5))],
            boundaries: boundaries, duration: 1, velocity: SIMD3(1, 0, 0), maximumMembers: maximumMembers)
    }

    @Test("Newly wet and dying members share existing gas; final scatter conserves every lane")
    func conservativeScatter() throws {
        let plan = try slabPlan()
        #expect(plan.members == [[0, 1]])
        #expect(plan.cellToGroup == [0, 0])
        #expect(plan.faces.isEmpty)
        #expect(plan.cells[0].amount[0] == 2)
        let scattered = try plan.scatter([.init(volume: 1, amount: plan.cells[0].amount)])
        #expect(scattered[0].volume == 0 && scattered[0].amount == .zero)
        #expect(scattered[1].amount == plan.cells[0].amount)
        #expect(scattered[1].pressure() > 0)
    }

    @Test("Member limits, inconsistent swept volumes and wrong scatter volumes fail")
    func rejectedPlans() throws {
        #expect(throws: MovingConnectedGasGroups.Failure.unsupportedGroup) {
            try slabPlan(maximumMembers: 1)
        }
        #expect(throws: MovingConnectedGasGroups.Failure.invalidGeometry) {
            try slabPlan(final: [0.1, 0.9])
        }
        let plan = try slabPlan()
        #expect(throws: MovingConnectedGasGroups.Failure.invalidState) {
            try plan.scatter([.init(volume: 0.9, amount: plan.cells[0].amount)])
        }
        let before = plan.cells[0].amount
        #expect(throws: FractionalEulerFlux.Failure.unstableStep) {
            try MovingGroupedGasFlux.advance(plan, exterior: .init(volume: 1, density: 2, pressure: 101325))
        }
        #expect(plan.cells[0].amount == before)
    }

    @Test("A thin rotated gas corner retains its analytical tetrahedral volume and face areas")
    func thinCorner() throws {
        let normal = simd_normalize(SIMD3<Double>(1, 1, 1))
        let distance = 1e-6
        let leg = sqrt(3.0) * distance
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 4),
            position: normal * (sqrt(3.0) - distance - 2),
            orientation: simd_quatd(from: SIMD3(1, 0, 0), to: normal))
        let geometry = FractionalBoxGeometry(body)
        let volume = geometry.gasVolume(lower: .zero, cellSize: 1)
        let expected = pow(leg, 3) / 6
        #expect(volume > 0)
        #expect(abs(volume / expected - 1) < 1e-6)
        let open = geometry.openFacePatches(lower: .zero, cellSize: 1)
        for axis in 0..<3 {
            #expect(abs(open[2 * axis].area) < 1e-20)
            let face = open[2 * axis + 1]
            #expect(abs(face.area / (leg * leg / 2) - 1) < 1e-6)
            var centroid = SIMD3<Double>(repeating: 1 - leg / 3)
            centroid[axis] = 1
            #expect(simd_distance(face.centroid, centroid) < 1e-10)
        }
    }

    @Test("A nonuniform static interval conserves gas and paired wall budgets after scatter")
    func pressurePulse() throws {
        let duration = 1e-6
        let centres = [SIMD3<Double>(0.5, 0.5, 0.5), SIMD3<Double>(1.5, 0.5, 0.5)]
        let old: [FractionalGasTransport.Cell] = [
            .init(volume: 1, density: 1.225, pressure: 120000),
            .init(volume: 1, density: 1.225, pressure: 101325),
        ]
        var boundaries: [MovingConnectedGasGroups.Boundary] = []
        for cell in 0..<2 {
            for side in 0..<6 where side / 2 > 0 || side == (cell == 0 ? 0 : 1) {
                var normal = SIMD3<Double>.zero
                normal[side / 2] = side % 2 == 0 ? -1 : 1
                boundaries.append(
                    .init(
                        geometry: .init(
                            cell: cell, area: 1, normal: normal,
                            centroid: centres[cell] + 0.5 * normal, owner: 1), meanTime: duration / 2))
            }
        }
        let plan = try MovingConnectedGasGroups.build(
            old: old, finalVolumes: [1, 1], meanVolumes: [1, 1],
            centres: centres, nominalVolume: 1,
            faces: [.init(a: 0, b: 1, area: 1, normal: SIMD3(1, 0, 0), centroid: SIMD3(1, 0.5, 0.5))],
            boundaries: boundaries, duration: duration, velocity: .zero)
        let result = try MovingGroupedGasFlux.advance(plan, exterior: old[0])
        let difference =
            result.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            - old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let impulse = result.wallImpulses.reduce(SIMD3<Double>.zero, +)
        #expect(abs(difference[0]) < 1e-12)
        #expect(abs(difference[4]) < 1e-9)
        #expect(simd_length(SIMD3(difference[1], difference[2], difference[3]) + impulse) < 1e-12)
        #expect(result.reservoirExchange == .zero)
        #expect(result.cells.allSatisfy { $0.pressure() > 0 })
        #expect(simd_length(result.cells[0].velocity) > 0)
    }

    @Test("Aligned and rotated wet/dry intervals preserve numerical comoving gas and wall budgets")
    func crossingStudy() throws {
        let rows = try ExperimentalMovingGroupsStudy.run(cellSizes: [0.2])
        #expect(rows.count == 4)
        for r in rows {
            #expect(r.transition == "dry-to-wet" ? r.dryToWetCells > 0 : r.wetToDryCells > 0)
            #expect(r.minimumOldGroupFraction >= 0.25)
            #expect(r.minimumFinalGroupFraction >= 0.25)
            #expect(r.maximumMembers <= 64)
            #expect(r.duration <= r.maximumStep)
            #expect(r.maximumRelativeDensityError < 1e-9)
            #expect(r.maximumRelativePressureError < 1e-9)
            #expect(r.maximumVelocityError < 1e-7)
            #expect(r.minimumPressure > 0)
            #expect(abs(r.massBudgetResidual) < 1e-10)
            #expect(simd_length(r.momentumBudgetResidual) < 1e-8)
            #expect(abs(r.energyBudgetResidual) < 1e-6)
            #expect(abs(r.impulseWorkResidual) < 1e-10)
        }
    }

    @Test("A finer rotated crossing rebuilds geometry after rejecting the acoustic timestep")
    func refinedRetry() throws {
        let rows = try ExperimentalMovingGroupsStudy.run(cellSizes: [0.1], rotations: [0.23])
        #expect(rows.count == 2)
        #expect(rows.contains { $0.rejectedSteps > 0 })
        for r in rows {
            #expect(r.transition == "dry-to-wet" ? r.dryToWetCells > 0 : r.wetToDryCells > 0)
            #expect(r.duration <= r.maximumStep)
            #expect(r.minimumOldGroupFraction >= 0.25 && r.minimumFinalGroupFraction >= 0.25)
            #expect(r.maximumRelativeDensityError < 1e-9)
            #expect(r.maximumRelativePressureError < 1e-9)
            #expect(r.minimumPressure > 0)
            #expect(abs(r.energyBudgetResidual) < 1e-6)
        }
    }
}
