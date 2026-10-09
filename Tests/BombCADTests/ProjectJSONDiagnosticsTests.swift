import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Project settings and view JSON diagnostics")
struct ProjectJSONDiagnosticsTests {
    private func archive() throws -> ProjectArchive {
        let scene = Scenario(
            name: "Package diagnostics", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(2, 2, 1)))
        return try ProjectDocument(scenario: scene).makeArchive()
    }

    private func payload(_ file: String, in archive: ProjectArchive) throws -> [String: Any] {
        let data = try #require(archive.files[file])
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectError(_ archive: ProjectArchive, message: String) throws {
        do {
            _ = try ProjectDocument(fileWrapper: archive.fileWrapper())
            Issue.record("Expected project open to fail")
        } catch {
            #expect(error.localizedDescription == message)
        }
    }

    @Test("Missing fields identify the package file and required field")
    func missingFields() throws {
        var project = try archive()
        var settings = try payload("settings.json", in: project)
        settings.removeValue(forKey: "duration")
        project.files["settings.json"] = try JSONSerialization.data(withJSONObject: settings)
        try expectError(
            project, message: "Project file \"settings.json\" is missing the required field \"duration\".")

        project = try archive()
        var view = try payload("view.json", in: project)
        view.removeValue(forKey: "distance")
        project.files["view.json"] = try JSONSerialization.data(withJSONObject: view)
        try expectError(
            project, message: "Project file \"view.json\" is missing the required field \"distance\".")
    }

    @Test("Wrong types and null values identify the field or array position")
    func invalidValues() throws {
        var project = try archive()
        var view = try payload("view.json", in: project)
        view["target"] = [0, "invalid", 0] as [Any]
        project.files["view.json"] = try JSONSerialization.data(withJSONObject: view)
        try expectError(
            project, message: "Project file \"view.json\" has the wrong value type at \"target[1]\".")

        project = try archive()
        var settings = try payload("settings.json", in: project)
        settings["resolution"] = NSNull()
        project.files["settings.json"] = try JSONSerialization.data(withJSONObject: settings)
        try expectError(
            project, message: "Project file \"settings.json\" requires a non-null value at \"resolution\".")
    }

    @Test("Valid JSON still receives the existing settings and view validation")
    func semanticValidation() throws {
        var project = try archive()
        var settings = try payload("settings.json", in: project)
        settings["duration"] = -1
        project.files["settings.json"] = try JSONSerialization.data(withJSONObject: settings)
        try expectError(project, message: "Project simulation settings are invalid.")

        project = try archive()
        var view = try payload("view.json", in: project)
        view["distance"] = -1
        project.files["view.json"] = try JSONSerialization.data(withJSONObject: view)
        try expectError(project, message: "Project camera or display settings are invalid.")
    }
}
