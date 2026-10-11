import BlastCore
import Foundation
import Metal
import Testing
import simd

@testable import BombCAD

/// IFC buildings imported as structures of shells and beams through the app's own path:
/// installed, standing under gravity, saved and reopened, resampled and judged.
@Suite(
    "IFC buildings as structures", .serialized,
    .enabled(if: IFCImporter.converterURL != nil, "Prepare the pinned IFC converter before integration tests")
)
struct IFCStructureImportTests {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Importer/Buildings/\(name)")
    }

    private func installed(_ name: String) async throws -> Scenario {
        let source = try await IFCImporter.convert(Data(contentsOf: fixture(name)))
        let domain = source.bounds.size + SIMD3(8, 8, 4)
        let corner = SIMD3<Float>(4, 4, 0)
        var model = ImportedModel(
            name: name, source: source, scale: 1, yUp: false, corner: corner, behavior: .deformable,
            preview: try source.transformed(scale: 1, yUp: false, corner: corner).preview(
                cellSize: 0.25, domain: domain))
        model.structuralOptions = IFCStructure.Options()
        var scene = Scenario(
            name: name, domainSize: domain, boxes: [], charge: Charge(mass: 0, position: SIMD3(1, 1, 0)))
        try scene.installImport(model, material: .reinforcedConcrete, fixedBase: true)
        return scene
    }

    @Test("The small house and the structural house import as shells and beams and stand under gravity")
    func stand() async throws {
        for name in ["building-architecture.ifc", "building-structural.ifc"] {
            let scene = try await installed(name)
            let imported = try #require(scene.importedModels?.first)
            let report = try #require(imported.structuralReport)
            #expect(imported.isStructural && report.members.contains { $0.role == .shell }, "\(name)")
            // Only the rigid parts' cells stay obstacles in the air.
            #expect(imported.rigidBoxes.count < imported.preview.boxes.count, "\(name)")
            let body = try #require(scene.structuralObjects.first?.structure)
            #expect(body.elementKind == .shell)
            let device = try #require(MTLCreateSystemDefaultDevice())
            let solver = try ShellSolver(device: device, model: body)
            solver.damping = 50
            solver.advance(steps: Int(0.3 / Double(solver.criticalTimeStep)))
            var mass: Float = 0
            solver.mutateNodes { mass = $0.reduce(0) { $0 + $1.mass } }
            let reaction = try #require(solver.anchorSummary()).reaction.z
            #expect(solver.summary().maxDisplacement < 2e-3, "\(name): \(solver.summary().maxDisplacement)")
            #expect(solver.summary().erodedElements == 0, "\(name)")
            #expect(
                abs(reaction - mass * 9.81) < 0.03 * mass * 9.81,
                "\(name): \(reaction) against \(mass * 9.81)")
        }
    }

    @Test(
        "A structural import saves as scene version 9, reopens, resamples and has no band where it is unlike")
    func persistence() async throws {
        let scene = try await installed("building-architecture.ifc")
        let archive = try ProjectDocument(scenario: scene).makeArchive()
        let header = try JSONSerialization.jsonObject(with: archive.files["scene.json"]!) as? [String: Any]
        #expect(header?["encodingVersion"] as? Int == 9)
        let restored = try ProjectDocument(archive: archive)
        #expect(restored.scenario == scene)
        #expect(
            restored.scenario.importedModels?.first?.structuralReport
                == scene.importedModels?.first?.structuralReport)
        // A finer air grid resamples the rigid parts and leaves the structure as it was.
        let fine = try restored.scenario.resamplingImports(cellSize: 0.125)
        #expect(fine.structuralObjects.first?.structure == scene.structuralObjects.first?.structure)
        #expect(fine.importedModels?.first?.preview.cellSize == 0.125)
        // Its walls' material is the default, assumed: the standing names that and gives no band.
        let standing = SceneStanding(StandingInputs(scenario: scene, cellSize: 0.25))
        #expect(standing[.structuralResponse]?.options.contains("Structure from IFC") == true)
        #expect(
            standing[.structuralResponse]?.unbanded?.contains { $0.contains("Structure from IFC unlike") }
                == true)
        #expect(standing.band(.peakDeflection) == nil)
    }
}
