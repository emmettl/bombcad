import DocumentKit
import Foundation
import Testing

@Suite("Project containers")
struct ProjectArchiveTests {
    private func archive() throws -> ProjectArchive {
        let data = Data("embedded geometry".utf8)
        let asset = ProjectManifest.Asset(path: "assets/source.obj", data: data)
        return try ProjectArchive(
            manifest: ProjectManifest(documentType: "bombcad", producer: "Tests", assets: [asset]),
            files: [
                "scene.json": Data("{}".utf8), "settings.json": Data("{}".utf8),
                asset.path: data, "results/note.txt": Data("retained optional file".utf8),
            ])
    }

    @Test("Package round trips preserve identity, embedded assets and optional files")
    func roundTrip() throws {
        let original = try archive()
        let loaded = try ProjectArchive(fileWrapper: original.fileWrapper())
        #expect(loaded.manifest == original.manifest)
        #expect(loaded.files == original.files)
    }

    @Test("Copied projects reopen independently and atomic replacement updates all payloads")
    func portableSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.bombcad")
        let copy = folder.appendingPathComponent("moved.bombcad")
        var original = try archive()
        try original.fileWrapper().write(to: first, options: .atomic, originalContentsURL: nil)
        try FileManager.default.copyItem(at: first, to: copy)
        try FileManager.default.removeItem(at: first)
        let loaded = try ProjectArchive.read(from: copy)
        #expect(loaded.files == original.files)
        original.files["settings.json"] = Data(#"{"changed":true}"#.utf8)
        try original.fileWrapper().write(to: copy, options: .atomic, originalContentsURL: copy)
        #expect(try ProjectArchive.read(from: copy).files == original.files)
        // Validation fails before a replacement wrapper is produced, leaving the saved project.
        original.files["settings.json"] = Data("invalid JSON".utf8)
        #expect(throws: (any Error).self) {
            try original.fileWrapper().write(to: copy, options: .atomic, originalContentsURL: copy)
        }
        #expect(try ProjectArchive.read(from: copy).files["settings.json"] == Data(#"{"changed":true}"#.utf8))
    }

    @Test("Unsupported versions are reported before decoding the rest of the manifest")
    func futureVersion() throws {
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(
                regularFileWithContents: Data(
                    #"{"format":"dev.simulationkit.project","schemaVersion":99}"#.utf8))
        ])
        do {
            _ = try ProjectArchive(fileWrapper: wrapper)
            Issue.record("Unsupported format was accepted")
        } catch ProjectFileError.unsupportedVersion(let version) {
            #expect(version == 99)
        }
    }

    @Test("Missing, corrupt and unregistered assets are rejected")
    func invalidAssets() throws {
        var project = try archive()
        project.files.removeValue(forKey: "assets/source.obj")
        #expect(throws: (any Error).self) { try project.validate() }
        project.files["assets/source.obj"] = Data("changed".utf8)
        #expect(throws: (any Error).self) { try project.validate() }
        project = try archive()
        project.files["assets/unregistered.obj"] = Data()
        #expect(throws: (any Error).self) { try project.validate() }
        project = try archive()
        project.manifest.assets.append(project.manifest.assets[0])
        #expect(throws: (any Error).self) { try project.validate() }
    }

    @Test("Traversal, conflicting paths, non-object JSON and oversized files are rejected")
    func invalidPayloads() throws {
        for path in ["../outside", "/absolute", "assets/../outside", "assets\\outside", "assets//empty"] {
            var project = try archive()
            project.files[path] = Data()
            #expect(throws: (any Error).self) { try project.validate() }
        }
        var project = try archive()
        project.files["results"] = Data()
        #expect(throws: (any Error).self) { try project.fileWrapper() }
        project = try archive()
        project.files["ASSETS/other.obj"] = Data()
        #expect(throws: (any Error).self) { try project.fileWrapper() }
        project = try archive()
        project.files["MANIFEST.JSON"] = Data()
        #expect(throws: (any Error).self) { try project.fileWrapper() }
        project = try archive()
        project.files["scene.json"] = Data("[]".utf8)
        #expect(throws: (any Error).self) { try project.validate() }
        project = try archive()
        project.files["results/large"] = Data(count: ProjectArchive.maximumFileBytes + 1)
        #expect(throws: (any Error).self) { try project.validate() }
    }

    @Test("Symbolic links are rejected by wrapper and bounded disk readers")
    func links() throws {
        let project = try archive()
        let wrapper = try project.fileWrapper()
        let link = FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/private/tmp"))
        link.preferredFilename = "linked"
        wrapper.addFileWrapper(link)
        #expect(throws: (any Error).self) { try ProjectArchive(fileWrapper: wrapper) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".bombcad")
        defer { try? FileManager.default.removeItem(at: url) }
        try project.fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        try FileManager.default.createSymbolicLink(
            at: url.appendingPathComponent("linked"), withDestinationURL: URL(fileURLWithPath: "/private/tmp")
        )
        #expect(throws: (any Error).self) { try ProjectArchive.read(from: url) }
    }
}
