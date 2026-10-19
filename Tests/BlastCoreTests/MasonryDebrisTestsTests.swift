import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// Keys's brick walls (`MasonryDebrisTests`) against the digitised histograms in
/// Fixtures/Keys2016.
@Suite("Brick walls' debris", .gpuThreads)
struct MasonryDebrisTestsTests {
    @Test("A slab thrown along the ground stops by Coulomb friction, at μg, chattering or not")
    func slidesToRest() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let h: Float = 0.0375
        let box = Box(min: SIMD3(1, 1, 0), max: SIMD3(1 + 27 * h, 1 + 27 * h, 3 * h))
        var material = StructureMaterial.masonry
        material.units = nil
        let model = StructureModel(solids: [box], material: material, elementSize: h, fixedBase: false)
        let structure = try StructureSolver(device: device, model: model)
        structure.groundFrictionCoefficient = 0.6
        structure.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].vx = 1 }
        }
        var mass: Float = 0
        structure.mutateNodes { nodes in for node in nodes { mass += node.mass } }
        func speed() -> Float { Float(structure.momentum().x) / mass }
        // v / (μ g) = 0.17 s to stop; at 0.1 s it should be at about 1 − 0.6 g × 0.1 = 0.41 m/s.
        let steps = Int((0.1 / Double(structure.criticalTimeStep)).rounded())
        structure.advance(steps: steps)
        #expect(abs(speed() - 0.41) < 0.08, "\(speed()) m/s at 0.1 s")
        structure.advance(steps: steps)
        #expect(abs(speed()) < 0.02, "\(speed()) m/s at 0.2 s")
    }

    @Test("On soft ground a slab settles by its weight over the bed, and still stops by friction at μg")
    func softGround() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let h: Float = 0.0375
        let box = Box(min: SIMD3(1, 1, 0), max: SIMD3(1 + 27 * h, 1 + 27 * h, 3 * h))
        var material = StructureMaterial.masonry
        material.units = nil
        let model = StructureModel(solids: [box], material: material, elementSize: h, fixedBase: false)
        let modulus: Float = 5e7
        func slab(sliding: Float) throws -> (StructureSolver, Float) {
            let structure = try StructureSolver(device: device, model: model)
            structure.groundFrictionCoefficient = 0.6
            structure.groundStiffness = modulus
            structure.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].vx = sliding }
            }
            var mass: Float = 0
            structure.mutateNodes { nodes in for node in nodes { mass += node.mass } }
            return (structure, mass)
        }
        // At rest: each node on the ground bears on h² of a bed of the modulus, so the slab sinks
        // by its weight over that bed.
        let (resting, mass) = try slab(sliding: 0)
        resting.advance(steps: Int((0.2 / Double(resting.criticalTimeStep)).rounded()))
        let bearing = Float((resting.ex + 1) * (resting.ey + 1)) * h * h
        let expected = mass * resting.gravity / (modulus * bearing)
        var sunk: Float = 0
        for j in 0...resting.ey {
            for i in 0...resting.ex { sunk -= resting.displacement(i, j, 0).z }
        }
        sunk /= Float((resting.ex + 1) * (resting.ey + 1))
        #expect(abs(sunk - expected) < 0.1 * expected, "sank \(sunk * 1e3) mm against \(expected * 1e3) mm")
        // Thrown along it at 1 m/s, it stops in about v / (μ g) = 0.17 s, as on the hard ground.
        let (thrown, _) = try slab(sliding: 1)
        thrown.advance(steps: Int((0.25 / Double(thrown.criticalTimeStep)).rounded()))
        let speed = Float(thrown.momentum().x) / mass
        #expect(abs(speed) < 0.02, "\(speed) m/s at 0.25 s")
    }
}
