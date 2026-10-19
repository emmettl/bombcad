import BlastModel
import Foundation
import Metal
import simd

extension PushOffTest {
    /// Drives one element `size` on a side along the specimen's path: its low-x face held, its
    /// high-x face opened to the initial width, then moved along the path, opening across x and
    /// sliding along z, over `stepsPerMillimetre` time steps per millimetre of the path, and then
    /// on through `beyond` (slip and width, m), if given.
    public static func run(
        device: MTLDevice, specimen: Specimen, size: Float = 0.05,
        stepsPerMillimetre: Int = 4000, beyond: [SIMD2<Float>] = [],
        adjust: (inout StructureModel) -> Void = { _ in }
    ) throws -> Result {
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
        var model = StructureModel(
            solids: [cube], material: material(for: specimen), elementSize: size, fixedBase: false)
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model.loadedSlowly())
        solver.gravity = 0
        solver.groundContact = false

        // The crack's width is the opening past the strain at which it formed.
        let material = model.material
        let onset = material.tensileStrength / material.youngsModulus * size
        let legs = [SIMD2<Float>(0, 0)] + (specimen.path + beyond).map { SIMD2($0.x, $0.y + onset) }
        var samples: [Sample] = []
        let stepsPerSample = 10
        for (from, to) in zip(legs, legs.dropFirst()) {
            let length = simd_length(to - from)
            let count = max(
                1, Int((length * 1000 * Float(stepsPerMillimetre) / Float(stepsPerSample)).rounded()))
            let duration = Float(count * stepsPerSample) * solver.criticalTimeStep
            let velocity = (to - from) / duration
            solver.mutateNodes { nodes in
                for k in 0...1 {
                    for j in 0...1 {
                        nodes[solver.nodeIndex(0, j, k)].isFixed = true
                        nodes[solver.nodeIndex(1, j, k)].isPrescribed = true
                        nodes[solver.nodeIndex(1, j, k)].velocity = SIMD3(velocity.y, 0, velocity.x)
                    }
                }
            }
            for _ in 0..<count {
                solver.advance(steps: stepsPerSample)
                let moved = solver.displacement(1, 0, 0)
                let stress = solver.stress(0, 0, 0)
                samples.append(
                    Sample(slip: moved.z, width: moved.x - onset, shear: abs(stress[5]), normal: -stress[0]))
            }
        }
        return Result(specimen: specimen, samples: Array(samples.drop { $0.slip <= 0 }))
    }
}
