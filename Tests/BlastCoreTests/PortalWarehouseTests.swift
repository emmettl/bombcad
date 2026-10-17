import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The portal-frame warehouse sample (`ScenarioPreset.portalWarehouse`): its frames, purlins, rails
/// and profiled sheeting meshed as shells and run in the air.
@Suite("Portal-frame warehouse", .gpuThreads)
struct PortalWarehouseTests {
    @Test("The warehouse meshes its frames, purlins, rails and sheeting, the sheets' ribs on their skins")
    func meshes() throws {
        let model = try #require(ScenarioPreset.portalWarehouse.scenario.structure)
        let expanded = model.expandingSheets()
        #expect(expanded.materials.count <= StructureModel.maxMaterials, "\(expanded.materials.map(\.name))")
        let mesh = try ShellMesh(model: expanded)
        print("Warehouse: \(mesh.elements.count) shells, \(mesh.beams.count) beams")
        // The five sheets: walls and roof closed, about 1,580 m² of skin.
        let sheets = (0..<model.solids.count).filter { model.sheet(of: $0) != nil }
        #expect(sheets.count == 5)
        let skin = mesh.elements.filter { sheets.contains($0.solid) }.reduce(Float(0)) {
            $0 + $1.size.x * $1.size.y
        }
        #expect(abs(skin - (30 * 24 + 2 * (30 + 24) * 8)) < 20, "skin \(skin) m²")
        // Every rib shares its skin's nodes.
        let nodes = Set(
            mesh.elements.filter { sheets.contains($0.solid) }.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let ribs = mesh.beams.filter { $0.solid >= model.solids.count }
        #expect(
            !ribs.isEmpty && ribs.allSatisfy { nodes.contains($0.nodes[0]) && nodes.contains($0.nodes[1]) })
    }

    @Test("The warehouse runs in the air: its time step reasonable, its front gable pushed in")
    func runs() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = ScenarioPreset.portalWarehouse.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let shells = try #require(solver.shells)
        print("Warehouse shell step \(shells.criticalTimeStep * 1e6) µs")
        #expect(shells.criticalTimeStep > 5e-6)
        // The wave reaches the front gable, 30 m off, at about 50 ms.
        solver.advance(until: 0.09)
        let front = shells.nearestNode(to: SIMD3(35, 40, 4))
        let push = shells.node(front).displacement.y
        print("Front gable's middle moved \(push * 1000) mm")
        #expect(push.isFinite && push > 0.001)
    }
}
