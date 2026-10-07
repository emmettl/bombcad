import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Repository importer samples")
struct ImporterSampleTests {
    // Read the actual repository examples; they are not SwiftPM or app resources.
    private var sampleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Importer")
    }
    private func data(_ file: String) throws -> Data {
        try Data(contentsOf: sampleDirectory.appendingPathComponent(file))
    }
    private func mesh(_ file: String) throws -> ImportedMesh {
        try ImportedMesh(
            data: data(file), fileExtension: URL(fileURLWithPath: file).pathExtension)
    }
    private func preview(_ mesh: ImportedMesh, h: Float = 0.25) throws -> ImportedMesh.Preview {
        try mesh.preview(cellSize: h, domain: SIMD3(repeating: 8))
    }
    @Test(
        "Every valid metre/Z-up sample can be previewed",
        arguments: [
            "unit-cube.obj", "named-parts.obj", "disconnected-blocks.stl", "narrow-gap.obj",
            "hollow-block.obj", "Repair/closed-box.obj", "Repair/merged-block.obj",
        ])
    func validSamples(file: String) throws {
        let result = try preview(mesh(file))
        #expect(result.occupiedCells > 0)
        #expect(!result.boxes.isEmpty)
    }
    @Test("Cube and STL samples preserve documented sizes, counts and names")
    func simpleSamples() throws {
        let cube = try mesh("unit-cube.obj")
        #expect(cube.bounds.max - cube.bounds.min == SIMD3(repeating: 1))
        #expect(try preview(cube).occupiedCells == 64)
        let stl = try mesh("disconnected-blocks.stl")
        #expect(stl.parts.map(\.name) == ["Component 1", "Component 2"])
        #expect(try preview(stl).occupiedCells == 128)
    }
    @Test("Named panel disappears on Medium and returns on Fine with thickness warnings")
    func thinPanel() throws {
        let source = try mesh("named-parts.obj")
        #expect(source.parts.map(\.name) == ["Concrete block", "Steel column", "Thin panel"])
        let panel = try #require(source.parts.last).id
        let medium = try preview(source)
        let fine = try preview(source, h: 0.125)
        #expect(medium.occupiedCells == 128)
        #expect(!Set(medium.boxPartIDs ?? []).contains(panel))
        #expect(fine.occupiedCells == 1088)
        #expect(Set(fine.boxPartIDs ?? []).contains(panel))
        #expect(fine.thinSpans > 0)
    }
    @Test("Narrow-gap sample warns even on Fine and preserves separate owners")
    func narrowGap() throws {
        let source = try mesh("narrow-gap.obj")
        for h: Float in [0.25, 0.125] {
            let result = try preview(source, h: h)
            #expect(result.smallGaps > 0)
            #expect(Set(result.boxPartIDs ?? []) == Set(source.parts.map(\.id)))
        }
        let result = try preview(source)
        #expect(result.occupiedCells == 128)
        #expect(result.boxes.contains { $0.contains(SIMD3(1.025, 0.5, 0.5)) })
    }
    @Test("Hollow sample keeps the cavity empty and assigns material to the outer solid")
    func cavity() throws {
        let source = try mesh("hollow-block.obj")
        let result = try preview(source)
        #expect(result.occupiedCells == 1664)
        #expect(!result.boxes.contains { $0.contains(SIMD3(1.5, 1.5, 1.5)) })
        #expect(Set(result.boxPartIDs ?? []) == [try #require(source.parts.first).id])
    }
    @Test("Millimetre Y-up example converts to a 1 by 2 by 3 metre column")
    func unitsAndAxis() throws {
        let source = try mesh("millimetres-y-up.obj")
        let converted = try source.transformed(scale: 0.001, yUp: true, corner: .zero)
        #expect(converted.bounds.min == .zero)
        #expect(simd_length(converted.bounds.max - SIMD3(1, 2, 3)) < 0.00001)
        #expect(try preview(converted).occupiedCells == 384)
    }
    @Test(
        "Broken samples are inspectable but rejected, and their repairs import",
        arguments: [
            ("Repair/open-box.obj", "Repair/closed-box.obj", 64),
            ("Repair/overlapping-blocks.obj", "Repair/merged-block.obj", 96),
        ])
    func repairWorkflow(broken: String, repaired: String, cells: Int) throws {
        let inspection = try ImportedMesh.inspect(data: data(broken), fileExtension: "obj")
        #expect(inspection.validatedMesh == nil)
        #expect(!inspection.issues.isEmpty)
        #expect(inspection.issues.contains { !$0.triangleIndices.isEmpty && $0.bounds != nil })
        #expect(throws: ImportedMesh.ImportError.self) { try mesh(broken) }
        #expect(try preview(mesh(repaired)).occupiedCells == cells)
    }
}
