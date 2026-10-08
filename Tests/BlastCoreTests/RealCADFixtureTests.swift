import CryptoKit
import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Real CAD export fixtures")
struct RealCADFixtureTests {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Importer/RealCAD")
    }
    private func data(_ file: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file))
    }
    private func mesh(_ name: String) throws -> ImportedMesh {
        try ImportedMesh(data: data("\(name).stl"), fileExtension: "stl")
    }
    private func millimetres(_ name: String) throws -> ImportedMesh {
        try mesh(name).transformed(scale: 0.001, yUp: false, corner: .zero)
    }
    private struct Manifest: Decodable {
        struct Model: Decodable {
            struct File: Decodable {
                var file: String
                var sha256: String
                var bytes: Int
            }
            var files: [File]
        }
        var formatVersion: Int
        var revision: String
        var models: [Model]
    }

    @Test("Pinned CAD exports retain the exact upstream bytes and usable STEP reference files")
    func inventory() throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data("manifest.json"))
        #expect(manifest.formatVersion == 1)
        #expect(manifest.revision.count == 40)
        #expect(manifest.models.count == 3)
        for model in manifest.models {
            #expect(model.files.count == 2)
            #expect(Set(model.files.map { URL(fileURLWithPath: $0.file).pathExtension }) == ["stl", "step"])
            for file in model.files {
                let bytes = try data(file.file)
                #expect(bytes.count == file.bytes)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                #expect(hash == file.sha256, "Unexpected change to upstream fixture \(file.file)")
                if file.file.hasSuffix(".step") {
                    let text = String(decoding: bytes, as: UTF8.self)
                    #expect(text.hasPrefix("ISO-10303-21;"))
                    #expect(text.contains("SI_UNIT(.MILLI.,.METRE.)"))
                    #expect(text.contains("END-ISO-10303-21;"))
                }
            }
        }
    }

    @Test(
        "Exporter-generated hollow block and curved pipe validate as single solids",
        arguments: [
            ("concrete-block", 372, SIMD3<Float>(390, 140, 190)),
            ("pvc-tee", 4004, SIMD3<Float>(82, 37.974648, 67)),
        ])
    func validExports(name: String, triangles: Int, size: SIMD3<Float>) throws {
        let source = try mesh(name)
        #expect(source.triangles.count == triangles)
        #expect(source.parts.count == 1)
        #expect(simd_length(source.bounds.size - size) < 0.0001)
        let transformed = try millimetres(name)
        #expect(transformed.bounds.min == .zero)
        #expect(simd_length(transformed.bounds.size - size * 0.001) < 0.000001)
        if name == "pvc-tee" { #expect(source.bounds.min.x < 0 && source.bounds.min.z < 0) }
    }

    @Test("Physical-scale hollow block reports coarse-grid loss; finer core sampling preserves openings")
    func blockResolution() throws {
        let source = try millimetres("concrete-block")
        let medium = try source.preview(cellSize: 0.25, domain: SIMD3(repeating: 1))
        let fine = try source.preview(cellSize: 0.125, domain: SIMD3(repeating: 1))
        #expect(medium.occupiedCells == 2 && fine.occupiedCells == 2)
        #expect(medium.thinSpans > 0 && fine.thinSpans > 0)
        #expect(fine.missedTriangles > 0)
        // This core-only spacing is deliberately finer than any grid offered by the app.
        let detailed = try source.preview(cellSize: 0.005, domain: SIMD3(repeating: 1))
        #expect(detailed.occupiedCells > fine.occupiedCells)
        #expect(detailed.boxes.contains { $0.contains(SIMD3(0.01, 0.01, 0.1)) })
        for hole in [SIMD3<Float>(0.1, 0.07, 0.1), SIMD3<Float>(0.28, 0.07, 0.1)] {
            #expect(!detailed.boxes.contains { $0.contains(hole) })
        }
    }

    @Test("Physical-scale PVC tee vanishes on app grids, with an empty bore after finer core sampling")
    func pipeResolution() throws {
        let source = try millimetres("pvc-tee")
        for h: Float in [0.25, 0.125] {
            let result = try source.preview(cellSize: h, domain: SIMD3(repeating: 1), allowEmpty: true)
            #expect(result.occupiedCells == 0 && result.boxes.isEmpty)
            #expect(result.missedTriangles == source.triangles.count)
            #expect(throws: ImportedMesh.ImportError.self) {
                try source.preview(cellSize: h, domain: SIMD3(repeating: 1))
            }
        }
        let detailed = try source.preview(cellSize: 0.005, domain: SIMD3(repeating: 1))
        #expect(detailed.occupiedCells > 0)
        #expect(detailed.thinSpans > 0 && detailed.missedTriangles > 0)
        let bore = SIMD3<Float>(0.078, 0.018987324, 0.019)
        #expect(!detailed.boxes.contains { $0.contains(bore) })
    }

    @Test("Unchanged window assembly opens defect inspection instead of entering the simulation")
    func windowAssembly() throws {
        let bytes = try data("casement-window.stl")
        let inspection = try ImportedMesh.inspect(data: bytes, fileExtension: "stl")
        #expect(inspection.triangles.count == 108)
        #expect(inspection.validatedMesh == nil)
        let issue = try #require(inspection.issues.first)
        #expect(issue.message.contains("intersect or touch ambiguously"))
        #expect(!issue.triangleIndices.isEmpty && issue.bounds != nil)
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportedMesh(data: bytes, fileExtension: "stl")
        }
    }
}
