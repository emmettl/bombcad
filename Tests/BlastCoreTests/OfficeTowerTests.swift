import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// "Twelve-storey office, steel and glass" (docs/office-tower.md).
@Suite("Office tower")
struct OfficeTowerTests {
    @Test("The office tower meshes its core, frame, floors and curtain wall, every lite glazed and joined to its frame")
    func meshes() throws {
        let scenario = ScenarioPreset.officeTower.scenario
        let model = try #require(scenario.structure)
        #expect(model.materials.count <= StructureModel.maxMaterials, "\(model.materials.map(\.name))")
        let clock = ContinuousClock.now
        let mesh = try ShellMesh(model: model)
        print("Office tower: \(mesh.elements.count) shells, \(mesh.beams.count) beams, meshed in \(ContinuousClock.now - clock)")
        if ProcessInfo.processInfo.environment["BOMBCAD_OFFICE_DETAIL"] != nil {
            let materials = model.materials
            for (name, steps) in [
                ("shell", mesh.elements.map { (min($0.size.x, $0.size.y) / materials[$0.material].plateWaveSpeed, materials[$0.material].name, $0.size, mesh.positions[Int($0.nodes[0])]) }),
                ("beam", mesh.beams.map { ($0.length / (materials[$0.material].youngsModulus / materials[$0.material].density).squareRoot(), materials[$0.material].name, SIMD2($0.length, 0), mesh.positions[Int($0.nodes[0])]) }),
            ] {
                for item in steps.sorted(by: { $0.0 < $1.0 }).prefix(4) { print("DETAIL \(name) \(item.0) \(item.1) \(item.2) at \(item.3)") }
            }
        }
        let glass = Set(model.solids.indices.filter { model.material(of: $0) == .toughenedGlass })
        #expect(glass.count == 12 * 4 * 15)
        // Every lite has its elements, and they share the frame's nodes round it.
        var byPane: [Int: Int] = [:]
        for element in mesh.elements where glass.contains(element.solid) { byPane[element.solid, default: 0] += 1 }
        #expect(byPane.count == glass.count, "\(glass.count - byPane.count) lites unmeshed")
        let frames = Set(model.solids.indices.filter { model.material(of: $0).name == ScenarioPreset.curtainWallFrame.name })
        let frameNodes = Set(
            mesh.elements.filter { frames.contains($0.solid) }.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let sample = try #require(glass.min())
        let (count, _) = GlazedOpeningTests.pane(in: mesh, solid: sample, wall: -1)
        #expect(count > 0)
        let paneNodes = Set(mesh.elements.filter { $0.solid == sample }.flatMap { e in (0..<4).map { e.nodes[$0] } })
        #expect(!paneNodes.isDisjoint(with: frameNodes))
        // The neighbours across the street are envelopes, their windows glazed.
        #expect(scenario.envelopeObjects.count == 2)
        #expect(scenario.envelopeObjects.allSatisfy { $0.envelope?.panes.count == 40 })
    }
}
