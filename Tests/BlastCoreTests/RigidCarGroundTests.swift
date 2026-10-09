import Foundation
import Testing
import simd

@testable import BlastCore

/// Mechanical checks of the simplified car against statics and rigid-body dynamics. These test
/// that the equations are solved as intended; none is a validation against a blast experiment.
@Suite("Rigid car ground contact")
struct RigidCarGroundTests {
    private let g = 9.81

    /// The saloon with its centre of mass moved off the centreline, so no load is symmetric.
    private func offsetCar(
        rolled angle: Double = 0, staticFriction: Double = 0.8, slidingFriction: Double = 0.7
    ) throws -> RigidCarDefinition {
        try RigidCarDefinition(
            name: "Offset", position: SIMD3(0, 0, 0.775 * sin(angle)), mass: 1500, wheelbase: 2.7,
            track: 1.55, centreOfMass: SIMD3(0.15, 0.04, 0.55), inertia: SIMD3(550, 2500, 2700),
            shellSize: SIMD3(4.6, 1.55, 1.3), groundClearance: 0.15,
            orientation: simd_quatd(angle: angle, axis: SIMD3(1, 0, 0)).vector,
            staticFriction: staticFriction, slidingFriction: slidingFriction)
    }

    /// Tyre forces (N) in FL, FR, RL, RR order, and the total shell force.
    private func loads(_ contacts: [RigidCarBody.Contact], step: Double) -> ([Double], Double) {
        var tyres = [Double](repeating: 0, count: 4)
        var shell = 0.0
        for contact in contacts {
            switch contact.location {
            case .tyre(let n): tyres[n] += contact.normal / step
            case .shell: shell += contact.normal / step
            }
        }
        return (tyres, shell)
    }

    /// Loads that equal tyre stiffnesses give for a resultant weight W at (x, y) in the ground
    /// plane with extra first moments: N = W/4 + (Σ N x) x_i / L² + (Σ N y) y_i / t².
    private func equalStiffness(
        _ car: RigidCarDefinition, moment: SIMD2<Double>
    ) -> [Double] {
        car.tyreContacts.map {
            car.mass * g / 4 + moment.x * $0.x / (car.wheelbase * car.wheelbase)
                + moment.y * $0.y / (car.track * car.track)
        }
    }

    @Test("At rest the axle and side loads match statics and each tyre the equal-stiffness split")
    func resting() throws {
        for definition in [try RigidCarDefinition.saloon(), try offsetCar()] {
            var car = try definition.makeBody()
            let start = car.position
            let weight = definition.mass * g
            let expected = equalStiffness(
                definition, moment: weight * SIMD2(definition.centreOfMass.x, definition.centreOfMass.y))
            for _ in 0..<1000 {
                let (tyres, shell) = loads(
                    car.advanceWithGround(by: 0.001, ground: definition.ground), step: 0.001)
                #expect(shell == 0)
                for n in 0..<4 { #expect(abs(tyres[n] - expected[n]) < 1e-6 * weight) }
            }
            // The determinate statics: the front axle carries W b / L and the sides split by y.
            let b = definition.wheelbase / 2 + definition.centreOfMass.x
            #expect(abs(expected[0] + expected[1] - weight * b / definition.wheelbase) < 1e-9 * weight)
            #expect(
                abs(
                    expected[0] + expected[2]
                        - weight * (0.5 + definition.centreOfMass.y / definition.track)) < 1e-9 * weight)
            #expect(simd_distance(car.position, start) < 1e-7)
            #expect(simd_length(car.linearVelocity) < 1e-7)
            #expect(simd_length(car.angularVelocity) < 1e-7)
        }
        let saloon = try RigidCarDefinition.saloon()
        var car = try saloon.makeBody()
        let (tyres, _) = loads(car.advanceWithGround(by: 0.001, ground: saloon.ground), step: 0.001)
        #expect(abs(tyres[0] - 1500 * g * 1.5 / 5.4) < 1e-3)
        #expect(abs(tyres[3] - 1500 * g * 1.2 / 5.4) < 1e-3)
    }

    @Test("Static friction holds below mu W and the car slides above it, whatever the direction")
    func slidingThreshold() throws {
        let definition = try offsetCar(staticFriction: 0.6, slidingFriction: 0.6)
        let weight = definition.mass * g
        let directions: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-0.6, 0.8, 0)]
        for direction in directions {
            func run(fraction: Double) throws -> RigidCarBody {
                var car = try definition.makeBody()
                for _ in 0..<500 {
                    let contacts = car.advanceWithGround(
                        by: 0.001, ground: definition.ground, force: fraction * weight * direction)
                    for contact in contacts {
                        #expect(contact.normal >= 0)
                        let limit: Double = 0.6 * contact.normal * (1 + 1e-12)
                        #expect(simd_length(contact.tangent) <= limit)
                    }
                }
                return car
            }
            let start = try definition.makeBody().position
            let held = try run(fraction: 0.59)
            let sliding = try run(fraction: 0.61)
            #expect(simd_distance(held.position, start) < 1e-6)
            #expect(simd_length(held.linearVelocity) < 1e-6)
            #expect(simd_distance(sliding.linearVelocity, 0.01 * g * 0.5 * direction) < 1e-4)
        }
    }

    @Test("Braking on locked wheels moves load to the front axle by mu W h / L and stops at v²/2μg")
    func braking() throws {
        let definition = try RigidCarDefinition.saloon()
        let weight = definition.mass * g
        let mu = definition.slidingFriction
        let h = definition.centreOfMass.z
        var car = try definition.makeBody()
        let start = car.position
        car.applyImpulse(SIMD3(definition.mass * 15, 0, 0))
        let sliding = equalStiffness(
            definition, moment: SIMD2(weight * definition.centreOfMass.x + mu * weight * h, 0))
        let resting = equalStiffness(definition, moment: SIMD2(weight * definition.centreOfMass.x, 0))
        var energy = car.mechanicalEnergy()
        for step in 0..<3000 {
            let contacts = car.advanceWithGround(by: 0.001, ground: definition.ground)
            let (tyres, shell) = loads(contacts, step: 0.001)
            #expect(shell == 0)
            #expect(car.linearVelocity.x > -1e-7)
            #expect(car.mechanicalEnergy() <= energy + 1e-6)
            energy = car.mechanicalEnergy()
            let expected = step < 2000 ? sliding : step > 2300 ? resting : nil
            if let expected {
                for n in 0..<4 { #expect(abs(tyres[n] - expected[n]) < 1e-6 * weight) }
            }
            if step == 1000 {
                // The front axle gains exactly what the rear loses.
                #expect(
                    abs(tyres[0] + tyres[1] - weight * (1.5 + mu * h) / definition.wheelbase) < 1e-6 * weight)
                #expect(abs(car.linearVelocity.x - (15 - mu * g * 1.001)) < 1e-6)
            }
            #expect(simd_length(car.angularVelocity) < 1e-7)
        }
        #expect(abs(car.position.x - start.x - 15 * 15 / (2 * mu * g)) < 0.02)
        #expect(simd_length(car.linearVelocity) < 1e-7)
        #expect(abs(car.position.z - start.z) < 1e-7)
    }

    @Test("Sliding sideways after a lateral impulse moves load to the leading tyres by mu W h / t")
    func lateralSlide() throws {
        let definition = try offsetCar()
        let weight = definition.mass * g
        let mu = definition.slidingFriction
        let h = definition.centreOfMass.z
        var car = try definition.makeBody()
        car.applyImpulse(SIMD3(0, -definition.mass * 4, 0), at: car.position)
        let expected = equalStiffness(
            definition,
            moment: weight * SIMD2(definition.centreOfMass.x, definition.centreOfMass.y - mu * h))
        var energy = car.mechanicalEnergy()
        for _ in 0..<500 {
            let (tyres, _) = loads(car.advanceWithGround(by: 0.001, ground: definition.ground), step: 0.001)
            for n in 0..<4 { #expect(abs(tyres[n] - expected[n]) < 1e-6 * weight) }
            // The right-hand tyres lead and carry W/2 - W y/t + mu W h / t.
            let right =
                weight * (0.5 - definition.centreOfMass.y / definition.track + mu * h / definition.track)
            #expect(abs(tyres[1] + tyres[3] - right) < 1e-6 * weight)
            #expect(car.mechanicalEnergy() <= energy + 1e-6)
            energy = car.mechanicalEnergy()
        }
        #expect(abs(car.linearVelocity.y + 4 - mu * g * 0.5) < 1e-6)
        #expect(simd_length(car.angularVelocity) < 1e-7)
    }

    @Test("A steady sideways push holds the car on four tyres below its stability factor and tips it above")
    func staticStabilityFactor() throws {
        // A high friction coefficient stands in for a kerb: the car tips rather than slides.
        let definition = try RigidCarDefinition.saloon(staticFriction: 2, slidingFriction: 2)
        let weight = definition.mass * g
        let factor = definition.staticStabilityFactor
        #expect(abs(factor - 1.55 / 1.1) < 1e-12)
        for ratio in [0.95, 1.05] {
            var car = try definition.makeBody()
            let start = car.position
            var lifted = false
            for _ in 0..<500 {
                let contacts = car.advanceWithGround(
                    by: 0.001, ground: definition.ground, force: SIMD3(0, ratio * factor * weight, 0))
                let (tyres, _) = loads(contacts, step: 0.001)
                if ratio < 1 {
                    // The trailing (right) tyres keep W/2 (1 - push / SSF).
                    #expect(abs(tyres[1] + tyres[3] - weight / 2 * (1 - ratio)) < 1e-6 * weight)
                } else {
                    #expect(tyres[1] == 0 && tyres[3] == 0)
                    // Friction vanishes with the load.
                    for contact in contacts where contact.location == .tyre(1) || contact.location == .tyre(3)
                    {
                        #expect(contact.tangent == .zero)
                    }
                    lifted = lifted || car.tyrePoints[1].z > 0
                }
            }
            if ratio < 1 {
                #expect(simd_distance(car.position, start) < 1e-6)
                #expect(car.tyrePoints.allSatisfy { abs($0.z) < 1e-6 })
            } else {
                // A 5% overturning excess lifts the left tyres about 6 cm in half a second.
                #expect(lifted && car.tyrePoints[1].z > 0.04 && car.tyrePoints[3].z > 0.04)
                // The pivot tyres stay put, within the contact tolerance.
                #expect(abs(car.tyrePoints[0].z) < 1e-5 && abs(car.tyrePoints[2].z) < 1e-5)
                #expect(abs(car.tyrePoints[0].y - 0.775) < 1e-5)
            }
        }
    }

    /// Tilted onto the right-hand tyres at a roll angle from level, then released from rest.
    private func tilted(_ angle: Double, step: Double, duration: Double) throws -> (
        car: RigidCarBody, contacts: [RigidCarBody.Contact], gain: Double, energy: Double
    ) {
        let definition = try RigidCarDefinition.saloon(
            position: SIMD3(0, 0, 1.55 / 2 * sin(angle)),
            orientation: simd_quatd(angle: angle, axis: SIMD3(1, 0, 0)).vector)
        var car = try definition.makeBody()
        let initial = car.mechanicalEnergy()
        var gain = 0.0
        var contacts: [RigidCarBody.Contact] = []
        for _ in 0..<Int((duration / step).rounded()) {
            contacts = car.advanceWithGround(by: step, ground: definition.ground)
            gain = max(gain, car.mechanicalEnergy() - initial)
        }
        return (car, contacts, gain, initial)

    }

    /// Roll angle from level; positive lifts the left-hand side.
    private func roll(_ car: RigidCarBody) -> Double {
        let up = car.body.orientation.act(SIMD3<Double>(0, 0, 1))
        return atan2(-up.y, up.z)
    }

    @Test("Tilted onto two tyres, the car rocks back below atan(t/2h) and tips onto its side above it")
    func rockingAndTipping() throws {
        let balance = atan(try RigidCarDefinition.saloon().staticStabilityFactor)
        #expect(abs(balance - atan2(0.775, 0.55)) < 1e-12)
        let rocking = try tilted(balance - 0.05, step: 0.001, duration: 3)
        let tipping = try tilted(balance + 0.05, step: 0.001, duration: 3)
        #expect(abs(roll(rocking.car)) < 1e-4)
        #expect(abs(rocking.car.position.z - 0.55) < 1e-4)
        #expect(rocking.car.tyrePoints.allSatisfy { abs($0.z) < 1e-5 })
        #expect(abs(roll(tipping.car) - .pi / 2) < 1e-3)
        // On its side the right tyres and the shell's right face share the ground.
        #expect(abs(tipping.car.position.z - 0.775) < 1e-3)
        let (tyres, shell) = loads(tipping.contacts, step: 0.001)
        #expect(tyres[0] == 0 && tyres[2] == 0 && shell > 0)
        #expect(abs(tyres.reduce(0, +) + shell - 1500 * g) < 1e-6 * 1500 * g)
        for result in [rocking, tipping] {
            #expect(result.gain < 1e-5 * result.energy)
            #expect(simd_length(result.car.linearVelocity) < 1e-5)
        }
    }

    @Test("Tipping and braking trajectories converge at first order as the timestep is halved")
    func convergence() throws {
        // The roll angle 0.8 s into a topple, before the shell reaches the ground.
        let balance = atan(try RigidCarDefinition.saloon().staticStabilityFactor)
        let angles = try [0.004, 0.002, 0.001, 0.0005].map {
            roll(try tilted(balance + 0.05, step: $0, duration: 0.8).car)
        }
        let differences = zip(angles, angles.dropFirst()).map { abs($0 - $1) }
        #expect(differences[1] < 0.6 * differences[0])
        #expect(differences[2] < 0.6 * differences[1])
        #expect(differences[2] < 1e-3)

        func brakingError(step: Double) throws -> Double {
            let definition = try RigidCarDefinition.saloon()
            var car = try definition.makeBody()
            let start = car.position.x
            car.applyImpulse(SIMD3(definition.mass * 15, 0, 0))
            for _ in 0..<Int((1 / step).rounded()) {
                car.advanceWithGround(by: step, ground: definition.ground)
            }
            return abs(car.position.x - start - (15 - 0.5 * 0.7 * g))
        }
        let coarse = try brakingError(step: 0.004)
        let medium = try brakingError(step: 0.002)
        let fine = try brakingError(step: 0.001)
        #expect(medium < 0.6 * coarse)
        #expect(fine < 0.6 * medium)
        #expect(fine < 0.005)
    }

    @Test("Uplift releases every tyre's load and friction at once")
    func liftOff() throws {
        let definition = try RigidCarDefinition.saloon()
        var car = try definition.makeBody()
        let weight = definition.mass * g
        let contacts = car.advanceWithGround(
            by: 0.01, ground: definition.ground, force: SIMD3(0.1 * weight, 0, 2 * weight))
        #expect(contacts.allSatisfy { $0.normal == 0 && $0.tangent == .zero })
        #expect(abs(car.linearVelocity.x - 0.1 * g * 0.01) < 1e-12)
        #expect(abs(car.linearVelocity.z - g * 0.01) < 1e-12)
        #expect(
            car.advanceWithGround(by: 0.01, ground: definition.ground, force: SIMD3(0, 0, 2 * weight)).isEmpty
        )
    }
}
