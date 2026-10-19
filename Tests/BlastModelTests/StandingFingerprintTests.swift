import Foundation
import Testing

@testable import BlastModel

/// The standing table's identity is derived from what it says, the same on any Mac.
@Suite struct StandingFingerprintTests {
    @Test func theIdentityIsAHashOfTheTablesContent() throws {
        let identity = StandingFingerprint.current
        #expect(identity.hasPrefix("standing-") && identity.count == "standing-".count + 8)
        #expect(identity.dropFirst("standing-".count).allSatisfy { $0.isHexDigit })
        let text = StandingFingerprint.canonicalText
        #expect(String(format: "standing-%08llx", StandingFingerprint.fnv1a(text) >> 32) == identity)
        // Every option, figure and sample scene is in what it hashes.
        for option in ModelOption.allCases { #expect(text.contains("option \(option.rawValue) ")) }
        for figure in ValidationTables.figures { #expect(text.contains("\"\(figure.id)\"")) }
        for preset in ScenarioPreset.allCases { #expect(text.contains("scene \(preset.rawValue) ")) }
        // And the estimates' standing, worded from the figures.
        for line in FacadeLoadSurrogate.standing + HybridFarField.standing + ChargeInference.standing {
            #expect(text.contains(StandingFingerprint.canonical(line)))
        }
        #expect(ChargeInference.standing[0].contains(ValidationTables.figure("inferredBeirut").ratio))
        // A standing derived now is judged by it.
        let scene = SceneStanding(
            StandingInputs(scenario: ScenarioPreset.streetCanyon.scenario, cellSize: 0.25))
        #expect(scene.table == identity && SceneStanding.currentTable == identity)
    }

    @Test func theTextIsCanonical() {
        // Dictionaries and sets in any order, and floating-point numbers to six figures.
        #expect(
            StandingFingerprint.canonical(["b": 1.0, "a": 1.0 / 3])
                == StandingFingerprint.canonical(["a": 1.0 / 3, "b": 1.0]))
        #expect(
            StandingFingerprint.canonical(1.0 / 3) == "0.333333"
                && StandingFingerprint.canonical(Float(1)) == "1")
        #expect(
            StandingFingerprint.canonical(Set(["y", "x"])) == StandingFingerprint.canonical(Set(["x", "y"])))
        #expect(StandingFingerprint.fnv1a("a") != StandingFingerprint.fnv1a("b"))
    }

    @Test func numberedTablesStillReadAndShow() throws {
        var old = SceneStanding(
            StandingInputs(scenario: ScenarioPreset.streetCanyon.scenario, cellSize: 0.25))
        old.table = "standing-table-36"
        let decoded = try JSONDecoder().decode(SceneStanding.self, from: JSONEncoder().encode(old))
        #expect(decoded.table == "standing-table-36" && decoded.tableTitle == "standing table 36")
        let now = SceneStanding(
            StandingInputs(scenario: ScenarioPreset.streetCanyon.scenario, cellSize: 0.25))
        #expect(
            now.differences(from: decoded).contains { $0.hasPrefix("Judged by different standing tables") })
        #expect(now.tableTitle == "standing " + now.table.dropFirst("standing-".count))
    }
}
