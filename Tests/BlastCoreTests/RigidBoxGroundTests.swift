import Testing
import simd

@testable import BlastCore

@Suite("Rigid box ground contact")
struct RigidBoxGroundTests {
    @Test("A resting box is supported by its weight without drifting or spinning")
    func resting() throws {
        var body = try RigidBoxBody(mass: 2, size: SIMD3(2, 2, 0.5), position: SIMD3(0, 0, 0.25))
        for _ in 0..<1000 {
            let contacts = body.advanceWithGround(by: 0.001)
            #expect(abs(contacts.reduce(0) { $0 + $1.normal } - 2 * 9.81 * 0.001) < 1e-9)
        }
        #expect(simd_distance(body.position, SIMD3(0, 0, 0.25)) < 1e-7)
        #expect(simd_length(body.linearVelocity) < 1e-7)
        #expect(simd_length(body.angularVelocity) < 1e-7)
    }

    @Test("Static friction holds below mu mg and permits sliding above it")
    func slidingThreshold() throws {
        let ground = RigidBoxBody.Ground(staticFriction: 0.6, slidingFriction: 0.6)
        func run(fraction: Double) throws -> RigidBoxBody {
            var body = try RigidBoxBody(mass: 2, size: SIMD3(2, 2, 0.5), position: SIMD3(0, 0, 0.25))
            for _ in 0..<500 {
                let contacts = body.advanceWithGround(
                    by: 0.001, ground: ground, force: SIMD3(fraction * 2 * 9.81, 0, 0))
                for contact in contacts {
                    #expect(contact.normal >= 0)
                    #expect(simd_length(contact.tangent) <= 0.6 * contact.normal + 1e-12)
                }
            }
            return body
        }
        let held = try run(fraction: 0.59)
        let sliding = try run(fraction: 0.61)
        #expect(abs(held.position.x) < 1e-6)
        #expect(abs(held.linearVelocity.x) < 1e-6)
        #expect(abs(sliding.linearVelocity.x - 0.01 * 9.81 * 0.5) < 1e-4)
    }

    @Test("Sliding decelerates by mu g and stops without reversing; friction is isotropic")
    func slidingAndStopping() throws {
        let ground = RigidBoxBody.Ground(staticFriction: 0.4, slidingFriction: 0.4)
        for direction in [SIMD3<Double>(1, 0, 0), simd_normalize(SIMD3<Double>(1, 1, 0))] {
            var body = try RigidBoxBody(mass: 2, size: SIMD3(2, 2, 0.5), position: SIMD3(0, 0, 0.25))
            body.applyImpulse(10 * direction)
            for _ in 0..<500 { body.advanceWithGround(by: 0.001, ground: ground) }
            #expect(simd_distance(body.linearVelocity, (5 - 0.4 * 9.81 * 0.5) * direction) < 1e-4)
            for _ in 0..<1500 {
                body.advanceWithGround(by: 0.001, ground: ground)
                #expect(simd_dot(body.linearVelocity, direction) > -1e-7)
            }
            #expect(simd_length(body.linearVelocity) < 1e-7)
        }
    }

    @Test("Uplift releases support and friction immediately")
    func liftOff() throws {
        var body = try RigidBoxBody(mass: 2, size: SIMD3(2, 2, 0.5), position: SIMD3(0, 0, 0.25))
        let contacts = body.advanceWithGround(by: 0.01, force: SIMD3(4, 0, 40))
        #expect(contacts.allSatisfy { $0.normal == 0 && $0.tangent == .zero })
        #expect(abs(body.linearVelocity.x - 0.02) < 1e-12)
        #expect(abs(body.linearVelocity.z - (20 - 9.81) * 0.01) < 1e-12)
        #expect(body.position.z > 0.25)
        #expect(body.advanceWithGround(by: 0.01, force: SIMD3(4, 0, 40)).isEmpty)
    }

    @Test("Static and sliding coefficients give distinct holding and sliding resistance")
    func differentFrictionCoefficients() throws {
        let ground = RigidBoxBody.Ground(staticFriction: 0.6, slidingFriction: 0.4)
        var held = try RigidBoxBody(mass: 2, size: SIMD3(2, 2, 0.5), position: SIMD3(0, 0, 0.25))
        var sliding = held
        sliding.applyImpulse(SIMD3(10, 0, 0))
        for _ in 0..<500 {
            held.advanceWithGround(by: 0.001, ground: ground, force: SIMD3(0.59 * 2 * 9.81, 0, 0))
            sliding.advanceWithGround(by: 0.001, ground: ground)
        }
        #expect(abs(held.position.x) < 1e-6)
        #expect(abs(held.linearVelocity.x) < 1e-6)
        #expect(abs(sliding.linearVelocity.x - (5 - 0.4 * 9.81 * 0.5)) < 1e-4)
    }

    @Test("Sliding distance converges to the analytical trajectory as the timestep is halved")
    func slidingConvergence() throws {
        func error(step: Double) throws -> Double {
            var body = try RigidBoxBody(mass: 2, size: SIMD3(2, 2, 0.5), position: SIMD3(0, 0, 0.25))
            body.applyImpulse(SIMD3(10, 0, 0))
            for _ in 0..<Int((0.5 / step).rounded()) {
                body.advanceWithGround(by: step, ground: .init(staticFriction: 0.4, slidingFriction: 0.4))
            }
            return abs(body.position.x - (5 * 0.5 - 0.5 * 0.4 * 9.81 * 0.5 * 0.5))
        }
        let coarse = try error(step: 0.004)
        let medium = try error(step: 0.002)
        let fine = try error(step: 0.001)
        #expect(medium < 0.6 * coarse)
        #expect(fine < 0.6 * medium)
        #expect(fine < 0.002)
    }

    @Test("An inelastic ground impact removes kinetic energy without penetration")
    func impact() throws {
        var body = try RigidBoxBody(mass: 2, size: SIMD3(1, 1, 1), position: SIMD3(0, 0, 1))
        body.applyImpulse(SIMD3(4, 0, -10), at: body.position + SIMD3(0.2, 0, 0))
        var previous = body.kineticEnergy
        let initialEnergy = previous
        for _ in 0..<500 {
            body.advanceWithGround(by: 0.001, gravity: .zero)
            #expect(body.corners.allSatisfy { $0.z >= -1e-12 })
            #expect(body.kineticEnergy <= previous + 1e-7)
            previous = body.kineticEnergy
        }
        // With gravity disabled, an offset impact can leave the box airborne with residual spin.
        #expect(body.kineticEnergy < initialEnergy)
    }

    @Test("A box rocks back below its balance angle and topples above it, with converging energy error")
    func rockingAndTipping() throws {
        func run(angle: Double, step: Double) throws -> (RigidBoxBody, Double) {
            let height = cos(angle) + 0.5 * sin(angle)
            var body = try RigidBoxBody(
                mass: 2, size: SIMD3(1, 1, 2), position: SIMD3(0, 0, height),
                orientation: simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)))
            let initialEnergy = 2 * 9.81 * height
            var maximumEnergyGain = 0.0
            for _ in 0..<Int((2 / step).rounded()) {
                body.advanceWithGround(by: step)
                maximumEnergyGain = max(
                    maximumEnergyGain,
                    body.kineticEnergy + 2 * 9.81 * body.position.z - initialEnergy)
            }
            return (body, maximumEnergyGain)
        }
        let rocking = try run(angle: 0.2, step: 0.001)
        let tipping = try run(angle: 0.6, step: 0.001)
        let coarse = try run(angle: 0.6, step: 0.002)
        #expect(abs(rocking.0.position.z - 1) < 0.01)
        #expect(abs(tipping.0.position.z - 0.5) < 0.01)
        #expect(rocking.1 < 0.002)
        #expect(tipping.1 < 0.002)
        #expect(tipping.1 <= coarse.1 + 1e-10)
    }
}
