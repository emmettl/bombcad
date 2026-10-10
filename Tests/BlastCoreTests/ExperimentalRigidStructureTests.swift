import Metal
import Testing
import simd

@testable import BlastCore

/// Freestanding objects striking a deformable structure. Mechanical checks only.
@Suite("Rigid objects against deformable structures", .serialized)
struct ExperimentalRigidStructureTests {
    let device: MTLDevice
    init() throws { device = try #require(MTLCreateSystemDefaultDevice()) }

    /// A soft elastic material, so that the structure's time step is not tiny.
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 3e9, poissonRatio: 0.2)

    /// A 0.4 m box of 50 kg, its face `gap` from the wall's at x = 2, moving at `speed` towards it.
    private func scene(wall: Box, fixedBase: Bool, shells: Bool, gap: Double = 0.005) throws -> Scenario {
        var model = StructureModel(solids: [wall], material: material, elementSize: 0.1, fixedBase: fixedBase)
        if shells { model.elementKind = .shell }
        return Scenario(
            name: "Box and wall", domainSize: SIMD3(4, 2, 3), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 1, 0.3)), structure: model,
            rigidObjects: [
                try RigidObjectDefinition(
                    name: "Box", shape: .box(size: SIMD3(repeating: 0.4)),
                    position: SIMD3(2 - gap - 0.2, 1, Double(wall.min.z + wall.max.z) / 2), mass: 50)
            ])
    }

    @Test(
        "A box thrown into a free block conserves momentum and loses energy to it", arguments: [false, true])
    func freeBlock(shells: Bool) throws {
        let simulation = try ExperimentalRigidStructureSimulation(
            device: device,
            scenario: scene(
                wall: Box(min: SIMD3(2, 0.4, 1), max: SIMD3(2.2, 1.6, 2)), fixedBase: false, shells: shells))
        simulation.gravity = .zero
        simulation.ground = false
        switch simulation.structure {
        case .solid(let solver): solver.groundContact = false
        case .shell(let solver): solver.groundContact = false
        }
        simulation.applyImpulse(SIMD3(250, 0, 0), to: 0)
        let momentum = simulation.linearMomentum + simulation.structureMomentum
        let energy = simulation.kineticEnergy
        let steps = Int((0.03 / simulation.timeStep).rounded(.up))
        simulation.advance(steps: steps)
        let box = simulation.members[0]
        #expect(box.velocity.x < 4)
        #expect(simulation.reaction.x > 50)
        // Contact gives the structure what it takes from the box.
        let total = simulation.linearMomentum + simulation.structureMomentum
        #expect(simd_length(total - momentum) < 1e-4 * simd_length(momentum))
        #expect(
            simd_length(simulation.structureMomentum - simulation.reaction) < 1e-4 * simd_length(momentum))
        // Inelastic: the box loses more than the structure gains, and no energy appears.
        #expect(simulation.contactWork.members < 0)
        #expect(simulation.contactWork.structure > 0)
        #expect(simulation.contactWork.members + simulation.contactWork.structure <= 1e-9 * energy)
        #expect(simulation.kineticEnergy + simulation.structureKineticEnergy < energy)
    }

    @Test(
        "A box thrown into a wall stops against it and the wall takes the reaction", arguments: [false, true])
    func fixedWall(shells: Bool) throws {
        let simulation = try ExperimentalRigidStructureSimulation(
            device: device,
            scenario: scene(
                wall: Box(min: SIMD3(2, 0, 0), max: SIMD3(2.2, 2, 1.5)), fixedBase: true, shells: shells))
        simulation.gravity = .zero
        simulation.ground = false
        simulation.applyImpulse(SIMD3(250, 0, 0), to: 0)
        let start = simulation.linearMomentum
        let steps = Int((0.03 / simulation.timeStep).rounded(.up))
        var deepest = -Double.infinity
        let face = 2.0
        for _ in 0..<steps {
            simulation.advance(steps: 1)
            deepest = max(deepest, simulation.members[0].corners.map(\.x).max()! - face)
        }
        let box = simulation.members[0]
        // The box's momentum went into the wall, and nothing else pushed it.
        #expect(
            simd_length(simulation.linearMomentum - start + simulation.reaction) < 1e-9 * simd_length(start))
        #expect(simulation.reaction.x > 200)
        #expect(box.velocity.x < 0.5)
        // The wall's face gives, a little; the box does not pass into it.
        #expect(deepest < 0.03)
        #expect(simulation.contactWork.members + simulation.contactWork.structure <= 0)
    }
}
