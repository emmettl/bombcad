import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Bodies meshed partly with solid elements and partly with shells, tied together.
@Suite("Mixed bodies")
struct MixedStructureTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    static let elastic = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0)

    /// A strip 3 m long, 0.5 m wide and 0.25 m thick, clamped at x = 0; the first `solidLength`
    /// metres are solid elements, the rest shells.
    private func strip(solidLength: Float) -> StructureModel {
        let h: Float = 0.0625
        var solids: [Box] = []
        var kinds: [ElementKind] = []
        if solidLength > 0 {
            solids.append(Box(min: SIMD3(0, 0, 1), max: SIMD3(solidLength, 0.5, 1.25)))
            kinds.append(.solid)
        }
        if solidLength < 3 {
            solids.append(Box(min: SIMD3(solidLength, 0, 1), max: SIMD3(3, 0.5, 1.25)))
            kinds.append(.shell)
        }
        var model = StructureModel(solids: solids, material: Self.elastic, elementSize: h, fixedBase: false)
        model.elementKind = kinds[0]
        for (index, kind) in kinds.enumerated() { model.setElementKind(kind, of: index) }
        model.shellLayers = 4
        model.supports = [Box(min: SIMD3(-1, -1, 0), max: SIMD3(0, 2, 3))]
        return model
    }

    /// Tip deflection under gravity, settled by damping.
    private func sag(_ model: StructureModel) throws -> Float {
        let tip = SIMD3<Float>(3, 0.25, 1.125)
        if model.isMixed {
            let body = try MixedStructure(device: device, model: model)
            body.solids.groundContact = false
            body.shells.groundContact = false
            body.solids.damping = 40
            body.shells.damping = 40
            body.advance(steps: Int(1.0 / body.criticalTimeStep))
            #expect(!body.tiedNodes.isEmpty)
            return body.shells.node(body.shells.nearestNode(to: tip)).displacement.z
        }
        if model.elementKind == .shell {
            let solver = try ShellSolver(device: device, model: model)
            solver.groundContact = false
            solver.damping = 40
            solver.advance(steps: Int(1.0 / solver.criticalTimeStep))
            return solver.node(solver.nearestNode(to: tip)).displacement.z
        }
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        solver.damping = 40
        solver.advance(steps: Int(1.0 / solver.criticalTimeStep))
        let h = model.elementSize
        let i = Int((3 / h).rounded())
        let j = Int((0.25 / h).rounded())
        // Mean of the top and bottom faces at the tip.
        let k0 = Int(((1 - solver.origin.z) / h).rounded())
        return 0.5 * (solver.displacement(i, j, k0).z + solver.displacement(i, j, k0 + 4).z)
    }

    @Test("A cantilever strip half solid elements and half shells sags as beam theory says")
    func mixedCantilever() throws {
        // w = 12 rho g L^4 / (8 E t^2) for a strip of thickness t under its own weight.
        let expected = Float(12 * 2400 * 9.81 * pow(3.0, 4) / (8 * 20e9 * 0.25 * 0.25))
        let shells = try sag(strip(solidLength: 0))
        let mixed = try sag(strip(solidLength: 0.75))
        let solid = try sag(strip(solidLength: 3))
        #expect(abs(-shells - expected) / expected < 0.03, "shells \(shells) m, expected \(-expected) m")
        #expect(abs(-solid - expected) / expected < 0.03, "solid \(solid) m, expected \(-expected) m")
        // Tied through the thickness, the mixed strip agrees too (a tie to a single element's
        // corners instead let the moment in over one element and was 10% soft).
        #expect(abs(-mixed - expected) / expected < 0.03, "mixed \(mixed) m, expected \(-expected) m")
    }
}

extension MixedStructureTests {
    /// The cantilever wall preset, its bottom `solidHeight` metres solid elements and the rest
    /// shells (all solid if 3, all shells if 0).
    func wall(solidHeight: Float, mass: Float) throws -> (
        deflection: Float, summary: StructureSummary, tied: Int
    ) {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.charge.mass = mass
        var model = try #require(scenario.structure)
        let wall = model.solids[0]
        let reinforcement = model.reinforcement
        if solidHeight < 3 {
            var lower = wall
            lower.max.z = solidHeight
            var upper = wall
            upper.min.z = solidHeight
            model.solids = solidHeight > 0 ? [lower, upper] : [upper]
            model.solidReinforcement = []
            model.reinforcement = reinforcement
            if solidHeight > 0 {
                model.elementKind = .solid
                model.setElementKind(.shell, of: 1)
                model.shellElementSize = 0.25
            } else {
                model.elementKind = .shell
                model.elementSize = 0.25
            }
        }
        scenario.structure = model
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let result = solver.advance(until: 0.1)
        #expect(result.isStable)
        // Deflection of the top of the wall, mid-length.
        let top = SIMD3<Float>(18.125, 16, 3)
        var deflection: Float = 0
        if let shells = solver.shells {
            deflection = shells.node(shells.nearestNode(to: top)).displacement.x
        } else if let structure = solver.structure {
            let h = structure.model.elementSize
            let i = Int(((top.x - structure.origin.x) / h).rounded())
            let j = Int(((top.y - structure.origin.y) / h).rounded())
            let k = Int(((top.z - structure.origin.z) / h).rounded())
            deflection = structure.displacement(i, j, k).x
        }
        return (deflection, solver.bodySummary() ?? StructureSummary(), solver.mixed?.tiedNodes.count ?? 0)
    }

    @Test("A wall, solid elements at its base and shells above, bends with the blast like the all-solid wall")
    func mixedWallInBlast() throws {
        let solid = try wall(solidHeight: 3, mass: 50)
        let shells = try wall(solidHeight: 0, mass: 50)
        let mixed = try wall(solidHeight: 1, mass: 50)
        // About 12, 38 and 21 mm at 0.1 s: the shells' base bends more than the solid
        // elements' does, and the mixed wall, solid at its base, lies between.
        #expect(mixed.tied > 0)
        #expect(!mixed.summary.hasBlownUp)
        let low = min(solid.deflection, shells.deflection)
        let high = max(solid.deflection, shells.deflection)
        #expect(
            mixed.deflection > low && mixed.deflection < high,
            "solid \(solid.deflection) m, shells \(shells.deflection) m, mixed \(mixed.deflection) m")
    }
}
