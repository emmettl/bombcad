import Foundation
import Testing
import simd

@testable import BlastModel

/// The transport hub sample (`ScenarioPreset.transportHub`): the train shed's frames, Vierendeel
/// trusses, purlins and glass meshed as shells and beams, and the concourse beside it an envelope
/// glazed with laminated glass.
@Suite("Transport hub")
struct TransportHubTests {
    @Test("The hub meshes its shed and glazes its concourse with laminated glass, front and roof")
    func builds() throws {
        let scenario = ScenarioPreset.transportHub.scenario
        let model = try #require(scenario.structure)
        #expect(model.materials.count <= StructureModel.maxMaterials)
        let mesh = try ShellMesh(model: model)
        print("Hub: \(mesh.elements.count) shells, \(mesh.beams.count) beams")
        // The roof's glass, 36 × 48 m, meshed as shells; the frames as beams.
        let glass = (0..<model.solids.count).filter { model.material(of: $0) == .toughenedGlass }
        let area = mesh.elements.filter { glass.contains($0.solid) }.reduce(Float(0)) {
            $0 + $1.size.x * $1.size.y
        }
        #expect(abs(area - 36 * 48) < 10, "glass \(area) m²")
        #expect(mesh.beams.count > 500)
        // The concourse: sixteen front panes and twelve rooflights, laminated.
        let concourse = try #require(scenario.envelopeObjects.first)
        let envelope = try #require(concourse.envelope)
        #expect(envelope.panes.count == 28)
        #expect(envelope.panes.filter { $0.size.z < $0.size.x && $0.size.z < $0.size.y }.count == 12)
        #expect(scenario.envelopeConstruction(for: concourse.id).laminate == .facade)
    }
}
