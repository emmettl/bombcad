import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Cracks that soften by their strain averaged across their band (`crackAveraging`).
@Suite("Nonlocal cracking", .gpuThreads)
struct NonlocalCrackingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A plain concrete prism 0.1 m long and 0.03 m square on 10 mm elements, held at one end
    /// and pulled at the other until it has cracked through: the work done on it per unit area.
    private func fractureWork(averaging: Float?) throws -> Float {
        let h: Float = 0.01
        let prism = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.1, 0.03, 1.03))
        var material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6)
        material.poissonRatio = 0
        var model = StructureModel(solids: [prism], material: material, elementSize: h, fixedBase: false)
        model.crackAveraging = averaging
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 400
        let speed: Float = 0.01
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    nodes[solver.nodeIndex(0, j, k)].isFixed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].isPrescribed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].velocity = SIMD3(speed, 0, 0)
                }
            }
        }
        // To 0.5 mm, past the crack's softening, in steps of a twentieth of a millisecond.
        let window = 5e-5
        let steps = max(1, Int((window / Double(solver.criticalTimeStep)).rounded()))
        var work: Double = 0
        for _ in 0..<Int((0.0005 / Double(speed)) / window) {
            solver.advance(steps: steps)
            var force: Float = 0
            for k in 0...solver.ez {
                for j in 0...solver.ey { force -= solver.nodalForce(solver.ex, j, k).x }
            }
            work += Double(force) * Double(speed) * Double(steps) * Double(solver.criticalTimeStep)
        }
        return Float(work) / (0.03 * 0.03)
    }

    @Test("A crack dissipates its fracture energy once, averaged across its band or not")
    func energy() throws {
        let material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6)
        let local = try fractureWork(averaging: nil)
        let averaged = try fractureWork(averaging: 0.02)
        // The elastic energy left in the prism at the end is a small part of this.
        for work in [local, averaged] {
            #expect(abs(work - material.fractureEnergy) / material.fractureEnergy < 0.25, "\(work) J/m²")
        }
        #expect(abs(averaged - local) / local < 0.2, "\(averaged) against \(local) J/m²")
    }

    @Test("Nonlocal cracking is saved, and a body without it is unchanged")
    func saved() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        let data = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["crackAveraging"] == nil)
        model.crackAveraging = 0.05
        #expect(try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model)) == model)
    }
}
