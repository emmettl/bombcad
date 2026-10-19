import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Each shell element integrates through its thickness by its own material's rule
/// (`ShellSolver.thicknessRules`): timber's in its lamellae, Gauss-Legendre's otherwise.
@Suite("Rules through a shell's thickness", .gpuThreads)
struct ThicknessRuleTests {
    let concrete = StructureMaterial.reinforcedConcrete
    let glulam = StructureMaterial.timber(.gl24h, grainAxis: 2)

    @Test(
        "Timber that no shell uses leaves Gauss-Legendre's rule; timber shells beside others take their own")
    func rules() {
        let materials = [concrete, StructureMaterial.timber(.c24, lamellae: 3)]
        let legendre = ShellSolver.gaussLegendre(8)
        let alone = ShellSolver.thicknessRules(layers: 8, materials: materials, shellMaterials: [0])
        #expect(alone.rule == legendre && alone.legendre == 0 && alone.timber == 0)
        let timber = ShellSolver.thicknessRules(layers: 8, materials: materials, shellMaterials: [1])
        #expect(
            timber.rule == ShellSolver.thicknessRule(layers: 8, materials: [materials[1]])
                && timber.timber == 0)
        let both = ShellSolver.thicknessRules(layers: 8, materials: materials, shellMaterials: [0, 1])
        #expect(both.legendre == 8 && both.timber == timber.rule.count)
        #expect(Array(both.rule.prefix(8)) == legendre && Array(both.rule.dropFirst(8)) == timber.rule)
    }

    /// A 3 m concrete wall's nodes after 400 steps under a pressure on its face, by position, with or
    /// without a glulam column standing apart from it.
    private func wall(withColumn: Bool) throws -> [SIMD3<Float>: SIMD3<Float>] {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 0), max: SIMD3(0.2, 3, 3))], material: concrete, elementSize: 0.25,
            fixedBase: true)
        model.elementKind = .shell
        if withColumn {
            // Beyond the wall's ends, so that its grid lines (its faces' and centreline's) cut no
            // element of the wall, which is meshed as it is alone.
            model.solids.append(Box(min: SIMD3(2, 4.875, 0), max: SIMD3(2.25, 5.125, 3)))
            model.setMaterial(glulam, of: 1)
        }
        let solver = try ShellSolver(device: device, model: model)
        // The same step either way: the glulam's faster waves would shorten the stable one.
        solver.stepOverride = 2e-6
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: false, history: [SIMD2(0, 0), SIMD2(0.001, 50e3), SIMD2(1, 50e3)])
        solver.advance(steps: 400)
        var moved: [SIMD3<Float>: SIMD3<Float>] = [:]
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            for n in nodes.indices where positions[n].x < 1 { moved[positions[n]] = nodes[n].displacement }
        }
        return moved
    }

    @Test("A concrete wall moves the same, to the bit, with a glulam column beside it")
    func timberBeamLeavesTheSlab() throws {
        let alone = try wall(withColumn: false)
        let beside = try wall(withColumn: true)
        #expect(!alone.isEmpty && alone.count == beside.count)
        #expect(alone.contains { simd_length($0.value) > 1e-6 })
        #expect(alone.allSatisfy { beside[$0.key] == $0.value })
    }
}
