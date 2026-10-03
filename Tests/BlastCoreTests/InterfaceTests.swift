import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Joints between materials, and glass.
@Suite("Interfaces and glass")
struct InterfaceTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Two 50 mm elements in a row along x, the first of `first`, the second of `second`, pulled
    /// apart; the largest nominal stress they carry.
    private func pullApart(
        _ first: StructureMaterial, _ second: StructureMaterial, bond: SIMD2<Float>?, to strain: Float = 0.002
    ) throws -> Float {
        let size: Float = 0.05
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size)),
                Box(min: SIMD3(size, 0, 1), max: SIMD3(2 * size, size, 1 + size)),
            ], material: first, elementSize: size, fixedBase: false)
        model.setMaterial(second, of: 1)
        model.interfaceBond = bond
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let steps = 4000
        let rate = strain * 2 * size / (Float(steps) * solver.criticalTimeStep)
        solver.mutateNodes { nodes in
            for k in 0...1 {
                for j in 0...1 {
                    nodes[solver.nodeIndex(0, j, k)].isFixed = true
                    nodes[solver.nodeIndex(2, j, k)].isPrescribed = true
                    nodes[solver.nodeIndex(2, j, k)].velocity = SIMD3(rate, 0, 0)
                }
            }
        }
        var peak: Float = 0
        for _ in 0..<(steps / 20) {
            solver.advance(steps: 20)
            var force: Float = 0
            for k in 0...1 {
                for j in 0...1 { force += solver.nodalForce(2, j, k).x }
            }
            peak = max(peak, -force / (size * size))
        }
        return peak
    }

    @Test("Masonry bonded to concrete comes away at the bond's strength, not the masonry's")
    func bondStrength() throws {
        let bonded = try pullApart(.plainConcrete, .masonry, bond: StructureModel.masonryBond)
        let whole = try pullApart(.plainConcrete, .masonry, bond: nil)
        let bond = StructureModel.masonryBond.x
        #expect(abs(bonded - bond) / bond < 0.05, "bonded: \(bonded) Pa against \(bond) Pa")
        let masonry = StructureMaterial.masonry.tensileStrength
        #expect(abs(whole - masonry) / masonry < 0.05, "whole: \(whole) Pa against \(masonry) Pa")
    }

    /// A 1 m square pane of 6 mm annealed glass, held at its edges, facing a charge 3 m away.
    private func pane(charge: Float) throws -> StructureSummary {
        var model = StructureModel(
            solids: [Box(min: SIMD3(4, 1, 0.5), max: SIMD3(4.006, 2, 1.5))], material: .annealedGlass,
            elementSize: 0.125, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let edge: Float = 0.01
        model.supports = [
            Box(min: SIMD3(3, 0, 0), max: SIMD3(5, 1 + edge, 3)),
            Box(min: SIMD3(3, 2 - edge, 0), max: SIMD3(5, 3, 3)),
            Box(min: SIMD3(3, 0, 0), max: SIMD3(5, 3, 0.5 + edge)),
            Box(min: SIMD3(3, 0, 1.5 - edge), max: SIMD3(5, 3, 3)),
        ]
        let scenario = Scenario(
            name: "Pane", domainSize: SIMD3(8, 3, 3), boxes: [],
            charge: Charge(mass: charge, position: SIMD3(1, 1.5, 1)), gauges: [], structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
        solver.advance(until: 0.03)
        return try #require(solver.bodySummary())
    }

    @Test("A pane of annealed glass shatters in a modest blast and survives a faint one")
    func glassPane() throws {
        // The pane's natural period, about 34 ms, is long against the blast's, so it is the
        // impulse that breaks it: 1 kg at 3 m gives a reflected impulse near 360 Pa s, which by
        // hand bends it far past its strength; 0.5 g gives about 10 Pa s.
        let strong = try pane(charge: 1)
        let faint = try pane(charge: 0.0005)
        #expect(strong.erodedElements > 0, "the pane should break")
        #expect(faint.erodedElements == 0, "the pane should survive, \(faint.erodedElements) failed")
    }
}
