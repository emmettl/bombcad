import Metal
import Testing
import simd

@testable import BlastCore

/// Several freestanding objects with one in the air. Consistency checks only.
@Suite("Experimental rigid-world coupling", .serialized)
struct ExperimentalRigidWorldTests {
    let device: MTLDevice
    init() throws { device = try #require(MTLCreateSystemDefaultDevice()) }

    @Test("With one car, the world driver moves as the single-car driver does under a blast")
    func oneCarMatchesCarDriver() throws {
        var scene = Scenario(
            name: "One car", domainSize: SIMD3(8, 5, 3), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(4, 0.6, 0.3)))
        scene.rigidCars = [try .saloon(position: SIMD3(4, 2.5, 0))]
        let car = try ExperimentalRigidCarSimulation(device: device, scenario: scene, cellSize: 0.2)
        let world = try ExperimentalRigidWorldSimulation(device: device, scenario: scene, cellSize: 0.2)
        #expect(world.coupled == 0 && world.count == 1)
        while car.air.time < 0.01 - 1e-8 {
            try car.advance(steps: 1, timeLimit: 0.01)
            try world.advance(steps: 1, timeLimit: 0.01)
            #expect(abs(car.air.time - world.air.time) < 1e-12)
        }
        let member = try #require(world.members.first)
        #expect(simd_length(car.velocity) > 0.01)
        #expect(simd_distance(member.centreOfMass, car.position) < 1e-6)
        #expect(simd_length(member.velocity - car.velocity) < 1e-5 * simd_length(car.velocity))
    }

    @Test(
        "A car pushed into its neighbour moves it, and air, contact and gravity account for the row's momentum"
    )
    func rowMomentumBudget() throws {
        var scene = try ExperimentalRigidRowStudy.scenario(chargeMass: 0, count: 2)
        scene.domainSize.y = 8.4
        // Coarse air: this checks bookkeeping, not loads.
        let simulation = try ExperimentalRigidWorldSimulation(device: device, scenario: scene, cellSize: 0.3)
        #expect(simulation.coupled == 0)
        // Car 1 is in the air; shove it sideways towards Car 2, 0.85 m away.
        let push = SIMD3<Double>(0, 1500 * 6, 0)
        try simulation.applyImpulse(push, to: 0)
        var accounted = push
        while simulation.air.time < 0.2 - 1e-8 {
            try simulation.advance(steps: 1, timeLimit: 0.2)
            accounted += simulation.lastImpulse + simulation.lastContactImpulses.reduce(.zero, +)
        }
        accounted += 3000 * simulation.air.time * simulation.gravity
        let members = simulation.members
        #expect(members[1].velocity.y > 0.5)
        #expect(simd_length(simulation.linearMomentum - accounted) < 1e-6 * simd_length(push))
        // Never left overlapping.
        for corner in members[0].corners {
            let local = simd_quatd(vector: members[1].orientation).inverse.act(
                corner - (members[1].corners[0] + members[1].corners[7]) / 2)
            #expect(any(abs(local) .> SIMD3(2.3, 0.775, 0.65) - 1e-5))
        }
    }
}
