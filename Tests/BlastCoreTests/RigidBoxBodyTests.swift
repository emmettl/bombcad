import Testing
import simd

@testable import BlastCore

@Suite("Rigid box mechanics")
struct RigidBoxBodyTests {
    @Test("Uniform box moments agree with the analytical mass integrals")
    func massProperties() throws {
        let body = try RigidBoxBody(mass: 12, size: SIMD3(2, 4, 6))
        #expect(simd_distance(body.inertia, SIMD3(52, 40, 20)) < 1e-12)
        #expect(throws: RigidBoxBody.InvalidDefinition.self) {
            try RigidBoxBody(mass: 0, size: SIMD3(repeating: 1))
        }
        #expect(throws: RigidBoxBody.InvalidDefinition.self) {
            try RigidBoxBody(mass: 1, size: SIMD3(1, -1, 1))
        }
        #expect(throws: RigidBoxBody.InvalidDefinition.self) {
            try RigidBoxBody(mass: .infinity, size: SIMD3(repeating: 1))
        }
    }

    @Test("A central impulse gives J/m without spin; free fall follows the ballistic solution")
    func ballisticFlight() throws {
        var body = try RigidBoxBody(mass: 2, size: SIMD3(repeating: 1), position: SIMD3(0, 0, 30))
        body.applyImpulse(SIMD3(6, 0, 4))
        #expect(simd_distance(body.linearVelocity, SIMD3(3, 0, 2)) < 1e-12)
        #expect(body.angularMomentum == .zero)
        for _ in 0..<200 { body.advance(by: 0.01) }
        #expect(simd_distance(body.position, SIMD3(6, 0, 30 + 4 - 0.5 * 9.81 * 4)) < 1e-10)
        #expect(simd_distance(body.linearVelocity, SIMD3(3, 0, 2 - 9.81 * 2)) < 1e-10)
    }

    @Test("An offset impulse and rotated inertia give the correct world-space spin")
    func offsetImpulse() throws {
        var body = try RigidBoxBody(
            mass: 12, size: SIMD3(2, 4, 6), position: SIMD3(10, 20, 30),
            orientation: simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        body.applyImpulse(SIMD3(0, 0, 40), at: body.position + SIMD3(0, 1, 0))
        #expect(simd_distance(body.angularMomentum, SIMD3(40, 0, 0)) < 1e-12)
        // The body's y principal axis (I = 40) now points along world -x.
        #expect(simd_distance(body.angularVelocity, SIMD3(1, 0, 0)) < 1e-12)
    }

    @Test("Principal-axis spin rotates a point analytically and constant torque supplies angular impulse")
    func axialRotationAndTorque() throws {
        var body = try RigidBoxBody(mass: 12, size: SIMD3(2, 4, 6))
        body.applyImpulse(SIMD3(0, 20, 0), at: SIMD3(1, 0, 0))
        for _ in 0..<100 { body.advance(by: .pi / 200, gravity: .zero) }
        #expect(simd_distance(body.worldPoint(SIMD3(1, 0, 0)) - body.position, SIMD3(0, 1, 0)) < 1e-10)
        #expect(abs(body.kineticEnergy - (400.0 / 24 + 10)) < 1e-10)
        var driven = try RigidBoxBody(mass: 12, size: SIMD3(2, 4, 6))
        for _ in 0..<100 {
            driven.advance(by: 0.01, gravity: .zero, force: SIMD3(12, 0, 0), torque: SIMD3(0, 0, 20))
        }
        #expect(simd_distance(driven.position, SIMD3(0.5, 0, 0)) < 1e-10)
        #expect(simd_distance(driven.angularMomentum, SIMD3(0, 0, 20)) < 1e-10)
        #expect(
            simd_distance(
                driven.worldPoint(SIMD3(1, 0, 0)) - driven.position,
                SIMD3(cos(0.5), sin(0.5), 0)) < 1e-10)
    }

    @Test("Asymmetric free spin conserves angular momentum and its energy error converges")
    func freeSpinConvergence() throws {
        func run(step: Double) throws -> (Double, simd_quatd) {
            var body = try RigidBoxBody(mass: 12, size: SIMD3(2, 4, 6))
            body.applyImpulse(SIMD3(0, 20, 0), at: SIMD3(1, 0, 0))
            body.applyImpulse(SIMD3(0, 0, 30), at: SIMD3(0, 1, 0))
            let initialEnergy = body.kineticEnergy
            let momentum = body.angularMomentum
            for _ in 0..<Int((2 / step).rounded()) { body.advance(by: step, gravity: .zero) }
            #expect(body.angularMomentum == momentum)
            #expect(abs(simd_length(body.orientation.vector) - 1) < 1e-12)
            return (abs(body.kineticEnergy - initialEnergy), body.orientation)
        }
        let coarse = try run(step: 0.02)
        let fine = try run(step: 0.01)
        let reference = try run(step: 0.00125)
        #expect(fine.0 < coarse.0 * 0.4)
        #expect(fine.0 < 1e-3)
        let coarseAngle = (coarse.1 * reference.1.inverse).angle
        let fineAngle = (fine.1 * reference.1.inverse).angle
        #expect(abs(fineAngle) < abs(coarseAngle) * 0.4)
    }
}
