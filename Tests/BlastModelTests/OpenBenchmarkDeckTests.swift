import Foundation
import Testing

@testable import BlastModel

@Suite("Open benchmark input decks")
struct OpenBenchmarkDeckTests {
    private func data(_ name: String) throws -> Data {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appending(path: "Benchmarks/open/decks/\(name).json"))
    }

    @Test("Both frozen decks decode and conserve their represented source budgets")
    func decks() throws {
        for name in ["kb-surface-burst-free-field", "ufc-closed-room-gas-pressure"] {
            let deck = try OpenBenchmarkDeck.decode(data(name))
            try deck.validate()
            #expect(deck.runs.count == (name.hasPrefix("kb") ? 1 : 5))
        }
    }

    @Test("Unsupported physics, changed domains, invalid cells and changed budgets are refused")
    func rejects() throws {
        let good = try OpenBenchmarkDeck.decode(data("kb-surface-burst-free-field"))
        var bad = good
        bad.physics.afterburning = true
        #expect(throws: OpenBenchmarkDeck.Invalid.self) { try bad.validate() }
        bad = good
        bad.mesh.counts[0] = 64
        #expect(throws: OpenBenchmarkDeck.Invalid.self) { try bad.validate() }
        bad = good
        bad.runs[0].initialCells.append(bad.runs[0].initialCells[0])
        #expect(throws: OpenBenchmarkDeck.Invalid.self) { try bad.validate() }
        bad = good
        bad.runs[0].initialCells[0].index[0] = -1
        #expect(throws: OpenBenchmarkDeck.Invalid.self) { try bad.validate() }
        bad = good
        bad.runs[0].initialCells[0].internalEnergyJM3 *= 2
        #expect(throws: OpenBenchmarkDeck.Invalid.self) { try bad.validate() }
    }
}
