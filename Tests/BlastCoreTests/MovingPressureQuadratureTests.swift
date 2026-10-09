import Testing
import simd

@testable import BlastCore

@Suite("Moving pressure surface/time quadrature")
struct MovingPressureQuadratureTests {
    @Test("Affine surface pressure with a quadratic envelope recovers exact moving torque and work")
    func patch() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(-0.25, 0.5, 0.5))
        let velocity = SIMD3<Double>(0.5, 0, 0)
        let r = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            .integrate(lower: .zero, cellSize: 1, duration: 1, wallQuadrature: true)
        let patch = r.walls[1]
        #expect(patch.samples!.allSatisfy { $0.areaTime > 0 && $0.time > 0 && $0.time < 1 })
        let load = try MovingWallPressureQuadrature.integrate(
            patch, cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position,
            velocity: velocity, duration: 1, lengthScale: 1,
            pressure: { point, time in 2 + time * time + point.y * (1 + time + time * time) })
        #expect(simd_distance(load.impulse, SIMD3(-3.25, 0, 0)) < 1e-13)
        #expect(simd_distance(load.angularImpulse, SIMD3(0, 0, 11.0 / 72)) < 1e-13)
        #expect(abs(load.work + 1.625) < 1e-13)
        #expect(abs(load.work - simd_dot(velocity, load.impulse)) < 1e-13)
        // Apply the paired reaction through the existing extensive-packet interface.
        let initial = FractionalGasTransport.Cell(volume: 1, density: 10, velocity: velocity, pressure: 100)
        let gas = try FractionalGasTransport.advance(
            [initial], newVolumes: [1], transfers: [],
            walls: [load.gasReaction(cell: 0)])[0]
        #expect(gas.amount[0] == initial.amount[0])
        #expect(
            simd_length(SIMD3(gas.amount[1] - initial.amount[1], gas.amount[2], gas.amount[3]) + load.impulse)
                < 1e-13)
        #expect(abs(gas.amount[4] - initial.amount[4] + load.work) < 1e-13)
        // Evaluating pressure at the joint area/time centroid gives -3.125 and zero
        // torque here: it misses both time variance and the pressure/lever covariance.
        #expect(abs(load.impulse.x + 3.125) > 0.1 && load.angularImpulse.z > 0.1)
    }

    @Test("Samples remain valid through transient intersections with clear endpoints")
    func transient() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(-0.5, 0.5, 0.5))
        let velocity = SIMD3<Double>(2, 0, 0)
        let r = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            .integrate(lower: .zero, cellSize: 1, duration: 1, wallQuadrature: true)
        #expect(r.initialGasVolume == 1 && r.finalGasVolume == 1)
        #expect(r.walls.reduce(0) { $0 + $1.samples!.count } > 0)
        for wall in r.walls {
            _ = try MovingWallPressureQuadrature.integrate(
                wall, cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position,
                velocity: velocity, duration: 1, lengthScale: 1, pressure: { _, _ in 1 })
            for sample in wall.samples! {
                #expect(all(sample.point .>= SIMD3<Double>(repeating: -1e-12)))
                #expect(all(sample.point .<= SIMD3<Double>(repeating: 1 + 1e-12)))
            }
        }
    }

    @Test("Malformed samples and nonphysical prescribed pressures are rejected")
    func invalidSamples() throws {
        let body = try RigidBoxBody(mass: 1, size: SIMD3(repeating: 1), position: SIMD3(-0.25, 0.5, 0.5))
        let velocity = SIMD3<Double>(0.5, 0, 0)
        let original = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            .integrate(lower: .zero, cellSize: 1, duration: 1, wallQuadrature: true).walls[1]
        func load(_ patch: TranslatingBoxSpaceTimeGeometry.PatchIntegral, pressure: Double = 1) throws {
            _ = try MovingWallPressureQuadrature.integrate(
                patch, cellCentre: SIMD3(repeating: 0.5), initialCentreOfMass: body.position,
                velocity: velocity, duration: 1, lengthScale: 1, pressure: { _, _ in pressure })
        }
        for mode in 0..<6 {
            var patch = original
            patch.samples = original.samples!.map { node in
                .init(
                    point: node.point + (mode == 2 ? SIMD3(0.1, 0, 0) : .zero),
                    time: mode == 1 ? 1.1 : node.time,
                    areaTime: mode == 0 ? -node.areaTime : (mode == 3 ? 2 * node.areaTime : node.areaTime))
            }
            if mode == 4 { patch.samples = nil }
            if mode == 5 { patch.samples = [] }
            #expect(throws: MovingWallPressureQuadrature.Failure.invalidSamples) { try load(patch) }
        }
        for pressure in [0, -1, Double.nan, Double.infinity] {
            #expect(throws: MovingWallPressureQuadrature.Failure.invalidPressure) {
                try load(original, pressure: pressure)
            }
        }
    }

    @Test("Clipped moving boxes match independent divergence-theorem loads and expose centroid error")
    func wholeBox() throws {
        let rows = try ExperimentalMovingPressureStudy.run(cellSizes: [0.4, 0.2], timeSlices: [1, 4])
        #expect(rows.count == 8)
        for r in rows {
            #expect(r.sampled.relativeImpulseError < 1e-10)
            #expect(r.sampled.relativeAngularImpulseError < 1e-10)
            #expect(r.sampled.relativeWorkError < 1e-10)
            #expect(r.centroid.relativeImpulseError > 1e-6 || r.centroid.relativeAngularImpulseError > 1e-6)
            #expect(r.maximumRelativeSampleMomentResidual < 1e-10)
            #expect(r.minimumSamplePressure > 0 && r.wallSamples > r.wallPatches)
            #expect(abs(r.impulseWorkResidual) < 1e-9)
        }
        #expect(throws: ExperimentalMovingPressureStudy.Failure.invalidConfiguration) {
            try ExperimentalMovingPressureStudy.run(timeSlices: [0])
        }
    }
}
