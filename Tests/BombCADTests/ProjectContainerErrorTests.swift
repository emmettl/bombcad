import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Shared project-container errors")
struct ProjectContainerErrorTests {
    private func wrapper() throws -> FileWrapper {
        let scene = Scenario(
            name: "Container diagnostics", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(2, 2, 1)))
        return try ProjectDocument(scenario: scene).makeArchive().fileWrapper()
    }

    private func replace(_ file: String, data: Data, in wrapper: FileWrapper) throws {
        let previous = try #require(wrapper.fileWrappers?[file])
        wrapper.removeFileWrapper(previous)
        let replacement = FileWrapper(regularFileWithContents: data)
        replacement.preferredFilename = file
        wrapper.addFileWrapper(replacement)
    }

    private func expectError(_ wrapper: FileWrapper, message: String) {
        do {
            _ = try ProjectDocument(fileWrapper: wrapper)
            Issue.record("Expected invalid project to fail")
        } catch {
            #expect(error is ProjectFileError)
            #expect(error.localizedDescription == message)
        }
    }

    @Test(
        "Malformed package JSON identifies its file before application decoding",
        arguments: ["manifest.json", "scene.json", "settings.json", "view.json"])
    func malformed(file: String) throws {
        let project = try wrapper()
        try replace(file, data: Data("{".utf8), in: project)
        expectError(project, message: "\(file) is not valid JSON.")
    }

    @Test("Missing manifest metadata reaches the document error with its field path")
    func missingMetadata() throws {
        let project = try wrapper()
        let data = try #require(project.fileWrappers?["manifest.json"]?.regularFileContents)
        var manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        manifest.removeValue(forKey: "producer")
        try replace("manifest.json", data: JSONSerialization.data(withJSONObject: manifest), in: project)
        expectError(project, message: "manifest.json is missing the required field \"producer\".")
    }

    @Test("An unsupported package version is still reported before absent metadata")
    func unsupportedVersion() throws {
        let project = try wrapper()
        let manifest: [String: Any] = ["format": ProjectManifest.formatIdentifier, "schemaVersion": 99]
        try replace("manifest.json", data: JSONSerialization.data(withJSONObject: manifest), in: project)
        expectError(project, message: "This project uses format version 99. This app supports version 1.")
    }
}
