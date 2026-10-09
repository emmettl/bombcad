import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Exporting for rendering from the app", .serialized)
struct RenderExportTests {
    private func document(duration: Double = 0.004) -> ProjectDocument {
        var scene = Scenario(
            name: "Export", domainSize: SIMD3(repeating: 4),
            boxes: [Box(min: SIMD3(3, 0, 0), max: SIMD3(4, 4, 2))],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = duration
        var spec = FragmentSpec()
        spec.casingMass = 0.01
        spec.count = 50
        spec.tracers = 0
        document.fragments = spec
        var ground = GroundShockSpec()
        ground.line = .init(from: SIMD2(2.5, 2), to: SIMD2(2.5, 3.5), count: 4)
        document.groundShock = ground
        return document
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "render-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func wait(_ export: RenderExport) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while export.isRunning {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The scene, its volumes and the fragments are written beside each other")
    func export() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "Export.usda")
        // A scene the save panel agreed to replace.
        try Data("old".utf8).write(to: scene)
        let export = RenderExport()
        export.frameInterval = 2
        export.fields = ["peak", "overpressure"]
        export.start(document(), to: scene)
        #expect(export.isRunning)
        try await wait(export)
        #expect(export.state == .finished(scene, frames: 3))
        let volumes = RenderExport.volumes(for: scene)
        #expect(volumes.lastPathComponent == "Export.volumes")
        let files = try FileManager.default.contentsOfDirectory(atPath: volumes.path).sorted()
        #expect(files == ["blast.0000.vdb", "blast.0001.vdb", "blast.0002.vdb"])
        let text = try String(contentsOf: scene, encoding: .utf8)
        #expect(text.contains("rel field:peak") && text.contains("rel field:overpressure"))
        #expect(!text.contains("field:shock") && text.contains("def Points \"Fragments\""))
        #expect(text.contains("def Points \"GroundShock\"") && text.contains("primvars:verticalVelocity"))
    }

    @Test("Without volumes or fragments, only the scene; a volumes folder in the way is refused")
    func sceneOnly() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "Plain.usda")
        let export = RenderExport()
        export.fields = []
        export.includesFragments = false
        export.includesGroundShock = false
        export.start(document(), to: scene)
        try await wait(export)
        #expect(export.state == .finished(scene, frames: 1))
        let text = try String(contentsOf: scene, encoding: .utf8)
        #expect(!text.contains("def Volume") && !text.contains("Fragments") && !text.contains("GroundShock"))

        try FileManager.default.createDirectory(
            at: RenderExport.volumes(for: scene), withIntermediateDirectories: false)
        export.fields = ["shock"]
        export.start(document(), to: scene)
        try await wait(export)
        guard case .failed = export.state else {
            Issue.record("Expected a failure, got \(export.state)")
            return
        }
    }

    @Test("Cancelling stops the run and leaves no volumes behind")
    func cancel() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "Long.usda")
        let export = RenderExport()
        export.frameInterval = 1
        export.start(document(duration: 0.5), to: scene)
        let deadline = ContinuousClock.now + .seconds(60)
        while case .running(let fraction) = export.state, fraction == 0 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        export.cancel()
        try await wait(export)
        #expect(export.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: RenderExport.volumes(for: scene).path))
    }
}
