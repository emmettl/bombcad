import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Saved run rename feedback", .serialized)
struct SavedRunRenameTests {
    private func model() throws -> SimulationModel {
        var document = ProjectDocument()
        document.runSettings?.resolution = "coarse"
        document.savedRuns = [try SavedRunTests().fixture(), try SavedRunTests().fixture(name: "Other")]
        return SimulationModel(document: document)
    }

    @Test("Rejected names return useful errors without modifying the project")
    func rejectedNames() throws {
        let model = try model()
        let id = try #require(model.savedRuns.first?.id)
        let original = ProjectDocument(model: model)
        let cases = [
            (" \n\t", "Enter a run name."),
            (String(repeating: "x", count: 121), "Run names must be 120 characters or fewer."),
            (" other ", "A saved run already uses that name. Choose a unique name."),
        ]
        for (name, expected) in cases {
            var message: String?
            do { try model.renameRun(id: id, name: name) } catch { message = error.localizedDescription }
            #expect(message == expected)
            #expect(ProjectDocument(model: model) == original)
        }
        #expect(throws: (any Error).self) { try model.renameRun(id: UUID(), name: "New name") }
        #expect(ProjectDocument(model: model) == original)
    }

    @Test("Valid names are trimmed and saved; case-only renames keep the run identity and data")
    func acceptedNames() throws {
        let model = try model()
        var expected = try #require(model.savedRuns.first)
        try model.renameRun(id: expected.id, name: "  Renamed \n")
        expected.name = "Renamed"
        #expect(model.savedRuns.first == expected)
        try model.renameRun(id: expected.id, name: "RENAMED")
        expected.name = "RENAMED"
        #expect(model.savedRuns.first == expected)
        let restored = try ProjectDocument(archive: ProjectDocument(model: model).makeArchive())
        #expect(restored.savedRuns == model.savedRuns)
    }
}
