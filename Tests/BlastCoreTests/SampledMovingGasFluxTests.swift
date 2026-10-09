import Testing
import simd

@testable import BlastCore

@Suite("Sampled moving gas wall flux")
struct SampledMovingGasFluxTests {
    @Test("Sub-resolution corner contacts preserve canonical geometry moments with a positive sample")
    func tinyContact() throws {
        let body = try RigidBoxBody(
            mass: 1, size: SIMD3(repeating: 0.2),
            position: SIMD3(-0.1, -0.1 + 2.1e-7, -0.1 + 2.1e-7))
        let velocity = SIMD3<Double>(1, -1, -1)
        let r = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            .integrate(lower: .zero, cellSize: 1, duration: 1, wallQuadrature: true)
        let tiny = r.walls.filter { $0.areaTime > 0 }
        #expect(!tiny.isEmpty)
        for patch in tiny {
            #expect(patch.areaTime < 1e-14 && patch.samples!.count == 1)
            #expect(patch.samples![0].areaTime == patch.areaTime)
            _ = try MovingWallPressureQuadrature.integrate(
                patch, cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position,
                velocity: velocity, duration: 1, lengthScale: 1, pressure: { _, _ in 1 })
        }
    }

    @Test("Sample times weight endpoint pressure packets and the same correction reaches gas")
    func temporalPackets() throws {
        let initial = FractionalGasTransport.Cell(volume: 1, density: 1, pressure: 1)
        let speed = 0.4
        let dt = 0.01
        let velocity = SIMD3<Double>(speed, 0, 0)
        let points = [
            SIMD3<Double>(0.5 + speed * dt / 4, -0.25, 0),
            SIMD3<Double>(0.5 + speed * 3 * dt / 4, 0.75, 0),
        ]
        let samples = [
            TranslatingBoxSpaceTimeGeometry.WallSample(point: points[0], time: dt / 4, areaTime: 0.75 * dt),
            .init(point: points[1], time: 3 * dt / 4, areaTime: 0.25 * dt),
        ]
        let boundary = MovingConnectedGasGroups.Boundary(
            geometry: .init(
                cell: 0, area: 1, normal: SIMD3(1, 0, 0),
                centroid: SIMD3(0.5 + speed * 0.375 * dt, 0, 0), owner: 1),
            meanTime: 0.375 * dt, samples: samples)
        let plan = MovingConnectedGasGroups.Plan(
            members: [[0]], cellToGroup: [0], cells: [initial], finalVolumes: [1 + speed * dt],
            memberFinalVolumes: [1 + speed * dt], faces: [], boundaries: [boundary], duration: dt,
            velocity: velocity, oldCentres: nil, finalCentres: nil, memberFinalCentres: nil,
            finalFaces: nil, maximumAreaResidual: 0, maximumMomentResidual: 0, maximumVolumeResidual: 0)
        // Independent constant-area Euler stages supply endpoint wall pressures. The
        // quadrature moment is 3/8 of the interval, so a half-stage average is wrong.
        let wall = FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(1, 0, 0), area: 1, velocity: velocity)
        let first = try FractionalEulerFlux.advanceWithWalls(
            [initial], faces: [], walls: [wall], duration: dt)
        let second = try FractionalEulerFlux.advanceWithWalls(
            first.cells, faces: [], walls: [wall], duration: dt)
        let expected = 0.625 * first.wallImpulses[0] + 0.375 * second.wallImpulses[0]
        let update = try MovingGroupedGasFlux.advance(plan, exterior: initial, timeIntegration: .heun)
        #expect(simd_distance(update.wallImpulses[0], expected) < 1e-14)
        #expect(
            simd_distance(update.wallImpulses[0], 0.5 * (first.wallImpulses[0] + second.wallImpulses[0]))
                > 1e-7)
        let before = initial.amount
        let after = update.cells[0].amount
        #expect(simd_length(SIMD3(after[1] - before[1], after[2], after[3]) + expected) < 1e-14)
        #expect(abs(after[4] - before[4] + update.wallWork[0]) < 1e-14)
        #expect(abs(update.wallWork[0] - simd_dot(velocity, expected)) < 1e-14)
        let expectedTorque = SIMD3<Double>(
            0, 0, -0.09375 * (second.wallImpulses[0].x - first.wallImpulses[0].x))
        #expect(simd_distance(update.wallMomentImpulses[0], expectedTorque) < 1e-14)
        #expect(abs(expectedTorque.z) > 1e-7)
    }

    @Test("Sampled constant Euler walls agree with centroid loads through a real rotated crossing")
    func constantAgreement() throws {
        let time = try ExperimentalMovingGroupsStudy.eventTime(h: 0.2, angle: 0.23, opening: true)
        let plain = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: time - 2e-6, duration: 4e-6)
        let sampled = try ExperimentalMovingGroupsStudy.domain(
            h: 0.2, angle: 0.23, start: time - 2e-6, duration: 4e-6, surfaceQuadrature: true)
        #expect(plain.plan.members == sampled.plan.members)
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: sampled.plan.velocity, pressure: 101325)
        let a = try MovingGroupedGasFlux.advance(plain.plan, exterior: exterior)
        let b = try MovingGroupedGasFlux.advance(sampled.plan, exterior: exterior)
        #expect(a.wallImpulses.count == b.wallImpulses.count)
        for n in a.wallImpulses.indices {
            #expect(simd_distance(a.wallImpulses[n], b.wallImpulses[n]) < 1e-12)
            #expect(simd_distance(a.wallMomentImpulses[n], b.wallMomentImpulses[n]) < 1e-12)
        }
        for n in a.cells.indices { #expect(abs(a.cells[n].amount[4] - b.cells[n].amount[4]) < 1e-8) }
    }

    @Test("Nonuniform reconstructed pressure evolves with paired sampled force, torque and work")
    func pressureBudgets() throws {
        let h = 0.2
        let start = 0.0
        let dt = 2e-6
        let body = try ExperimentalMovingGroupsStudy.body(angle: 0.23, time: start)
        let geometry = FractionalBoxGeometry(body)
        let base = try ExperimentalMovingGroupsStudy.domain(h: h, angle: 0.23, start: start, duration: dt)
        let old = base.old.indices.map { n -> FractionalGasTransport.Cell in
            let lower = h * SIMD3<Double>(Double(n % 10), Double((n / 10) % 10), Double(n / 100))
            let volume = base.old[n].volume
            guard volume > 0 else { return .init(volume: 0, amount: .zero) }
            let nodes = geometry.gasQuadrature(lower: lower, cellSize: h)
            let weight = nodes.reduce(0) { $0 + $1.weight }
            let pressure =
                nodes.reduce(0) {
                    let offset = ($1.point - SIMD3(0.5, 1.18, 1.10)) / SIMD3(0.2, 0.25, 0.25)
                    return $0 + $1.weight * (101325 + 40000 * exp(-0.5 * simd_length_squared(offset)))
                } / weight
            return .init(volume: volume, density: 1.225, velocity: base.plan.velocity, pressure: pressure)
        }
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: h, angle: 0.23, start: start, duration: dt, previous: old, reconstruct: true,
            surfaceQuadrature: true)
        let exterior = FractionalGasTransport.Cell(
            volume: 1, density: 1.225, velocity: domain.plan.velocity, pressure: 101325)
        let r = try MovingGroupedGasFlux.advance(
            domain.plan, exterior: exterior, limited: true, timeIntegration: .heun)
        let before = old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = r.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let impulse = r.wallImpulses.reduce(SIMD3<Double>.zero, +)
        let work = r.wallWork.reduce(0, +)
        let residual = after - before - r.reservoirExchange
        #expect(
            abs(residual[0]) < 1e-10
                && simd_length(SIMD3(residual[1], residual[2], residual[3]) + impulse) < 1e-9)
        #expect(abs(residual[4] + work) < 1e-6 && abs(work - simd_dot(domain.plan.velocity, impulse)) < 1e-9)
        let angular = r.wallMomentImpulses.indices.reduce(SIMD3<Double>.zero) {
            $0 + r.wallMomentImpulses[$1] - simd_cross(body.position, r.wallImpulses[$1])
        }
        #expect(simd_length(impulse) > 1e-4 && simd_length(angular) > 1e-6)
        #expect(r.cells.filter { $0.volume > 0 }.allSatisfy { $0.pressure() > 0 })
        #expect(r.cells.contains { $0.volume > 0 && simd_length($0.velocity - domain.plan.velocity) > 1e-4 })
    }

    @Test("Sampled Heun transport preserves uniform and advected-density states")
    func repeatedTransport() throws {
        let rows = try ExperimentalMovingTrajectoryStudy.run(
            cellSizes: [0.2], duration: 0.000064, velocityScale: 1, nearCrossing: true,
            limited: true, secondOrder: true, surfaceQuadrature: true)
        for r in rows {
            let f = r.frames.last!
            #expect(r.wallIntegration == "surfaceTimeQuadrature")
            #expect(
                f.dryToWetCells == r.referenceDryToWetCells && f.wetToDryCells == r.referenceWetToDryCells)
            #expect(f.maximumRelativePressureError < 1e-9 && f.maximumVelocityError < 1e-7)
            #expect(abs(f.energyBudgetResidual) < 1e-6 && simd_length(f.bodyAngularImpulse) < 1e-8)
        }
        let entropy = try ExperimentalMovingEntropyStudy.run(
            cellSizes: [0.4], rotations: [0.23], cfls: [0.2], limited: true, secondOrder: true,
            surfaceQuadrature: true)[0]
        let f = entropy.frames.last!
        #expect(f.transport!.relativeDensityL1 < 0.04)
        #expect(f.maximumRelativePressureError < 1e-9 && f.maximumVelocityError < 1e-7)
        #expect(abs(f.energyBudgetResidual) < 1e-6 && abs(f.impulseWorkResidual) < 1e-9)
    }
}
