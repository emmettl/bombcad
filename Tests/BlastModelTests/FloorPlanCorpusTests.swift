import Foundation
import Testing

@testable import BlastModel

/// The plan importer against its corpus (Fixtures/FloorPlans, `Scripts/plans/make-corpus.py`):
/// each plan read as its JSON asks gives the answer expected of it, or a limitation it records.
@Suite("Floor plan corpus")
struct FloorPlanCorpusTests {
    @Test("Every plan in the corpus reads as expected, or as its recorded limitation says")
    func corpus() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/FloorPlans")
        let results = try FloorPlanCorpus.checkAll(folder: folder)
        #expect(results.count >= 25)
        for result in results where result.limitation == nil {
            #expect(result.failures.isEmpty, "\(result.name): \(result.failures) (\(result.summary))")
        }
        // The limitations still fail as they say: when one passes, its record should go.
        for result in results where result.limitation != nil {
            #expect(!result.failures.isEmpty, "\(result.name) now reads as expected: drop its limitation")
        }
    }
}
