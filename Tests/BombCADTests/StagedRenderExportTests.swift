import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Publishing render export files", .serialized)
struct StagedRenderExportTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "staged-export-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @Test("Publishing keeps relative asset names and replaces the scene only once files are ready")
    func publish() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "My Scene.usda")
        let old = Data("old scene".utf8)
        let new = Data("new scene".utf8)
        try old.write(to: scene)
        let staged = try StagedRenderExport(destination: scene, includesVolumes: true)
        defer { staged.discard() }
        #expect(staged.scene.lastPathComponent == scene.lastPathComponent)
        let volumes = try #require(staged.volumes)
        #expect(volumes.lastPathComponent == "My Scene.volumes")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: false)
        try new.write(to: staged.scene)
        try Data("volume".utf8).write(to: volumes.appending(path: "frame.vdb"))
        #expect(try Data(contentsOf: scene) == old)
        try staged.publish()
        staged.discard()
        #expect(try Data(contentsOf: scene) == new)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == ["My Scene.usda", "My Scene.volumes"])
        #expect(
            try Data(contentsOf: RenderExport.volumes(for: scene).appending(path: "frame.vdb"))
                == Data("volume".utf8))
    }

    @Test("A competing volume folder is preserved and prevents publication")
    func competingFolder() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "Scene.usda")
        let old = Data("old scene".utf8)
        try old.write(to: scene)
        let staged = try StagedRenderExport(destination: scene, includesVolumes: true)
        defer { staged.discard() }
        try Data("new scene".utf8).write(to: staged.scene)
        try FileManager.default.createDirectory(
            at: try #require(staged.volumes), withIntermediateDirectories: false)
        let destinationVolumes = RenderExport.volumes(for: scene)
        try FileManager.default.createDirectory(at: destinationVolumes, withIntermediateDirectories: false)
        let marker = destinationVolumes.appending(path: "other-export.txt")
        try old.write(to: marker)
        #expect(throws: (any Error).self) { try staged.publish() }
        staged.discard()
        #expect(try Data(contentsOf: scene) == old)
        #expect(try Data(contentsOf: marker) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test("A scene publication failure rolls back its newly moved volumes")
    func failedScenePublication() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "Scene.usda")
        let old = Data("old scene".utf8)
        try old.write(to: scene)
        let staged = try StagedRenderExport(destination: scene, includesVolumes: true)
        defer { staged.discard() }
        try FileManager.default.createDirectory(
            at: try #require(staged.volumes), withIntermediateDirectories: false)
        // Deliberately omit the staged scene to fail after the volumes have moved.
        #expect(throws: (any Error).self) { try staged.publish() }
        staged.discard()
        #expect(try Data(contentsOf: scene) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Scene.usda"])
    }

    @Test("An existing directory or dangling volume link is refused without changing it")
    func protectedDestinations() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scene = folder.appending(path: "Scene.usda")
        try FileManager.default.createDirectory(at: scene, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try StagedRenderExport(destination: scene, includesVolumes: false)
        }
        let otherScene = folder.appending(path: "Other.usda")
        let volumes = RenderExport.volumes(for: otherScene)
        try FileManager.default.createSymbolicLink(atPath: volumes.path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) {
            try StagedRenderExport(destination: otherScene, includesVolumes: true)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: volumes.path) == "missing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }
}
