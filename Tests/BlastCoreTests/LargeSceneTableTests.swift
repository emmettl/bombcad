import Foundation
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

// The large-scene comparison's numbers in ValidationTables, against docs/large-scenes.md. The
// helpers follow ErrorBandTests' for the validation record.

private let docs = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "docs")

/// GitHub's anchor for a heading.
private func anchor(_ heading: Substring) -> String {
    String(
        heading.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == " " { return "-" }
            if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return nil
        })
}

/// The header and rows of the first table under `link` whose header contains `header`, as cells.
private func table(_ link: String, header: String) throws -> (header: [String], rows: [[String]]) {
    let parts = link.split(separator: "#", maxSplits: 1).map(String.init)
    let lines = try String(contentsOf: docs.appending(path: parts[0]), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let start = try #require(
        lines.firstIndex { $0.hasPrefix("#") && anchor($0.drop { $0 == "#" }.drop { $0 == " " }) == parts[1] }
    )
    let head = try #require(lines[start...].firstIndex { $0.hasPrefix("|") && $0.contains(header) })
    func cells(_ line: String) -> [String] {
        line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    return (cells(lines[head]), lines[(head + 2)...].prefix { $0.hasPrefix("|") }.map(cells))
}

private func percent(_ cell: String) -> Double? { Double(cell.replacingOccurrences(of: "%", with: "")) }

@Suite("Large-scene tables", .timeLimit(.minutes(120)))
struct LargeSceneTableTests {
    private let link = "large-scenes.md#against-kingerybulmash-to-40-mkg13"

    @Test("The peak and impulse shares to 40 m/kg^(1/3) are the document's, cell for cell")
    func tablesMirrorTheDocument() throws {
        for (header, code) in [
            ("Scaled cell (finest) | Z", ValidationTables.farIncidentPeak),
            ("Grid | Scaled cell | Z", ValidationTables.farIncidentImpulse),
        ] {
            let parsed = try table(link, header: header)
            // The distances' columns; the peak table has the runs' cost after them.
            let columns = ValidationTables.farDistances.count
            let distances = parsed.header.dropFirst(2).prefix(columns).map {
                Double($0.replacingOccurrences(of: "Z = ", with: ""))
            }
            #expect(distances == ValidationTables.farDistances.map(Optional.some), "\(header)")
            for (grid, name) in ["16 m", "8 m", "4 m"].enumerated() {
                let row = try #require(parsed.rows.first { $0[0] == name }, "\(header): \(name)")
                #expect(
                    row.dropFirst(2).prefix(columns).map(percent) == code.byGrid[grid]!.map(Optional.some),
                    "\(header): \(name)")
            }
        }
        let impulse = try table(link, header: "Grid | Scaled cell | Z")
        let burning = try #require(impulse.rows.first { $0[0].contains("afterburning") })
        #expect(burning.dropFirst(2).map(percent) == ValidationTables.farBurningRow.map(Optional.some))
    }

    @Test("The refinement's reach is the document's: about 20 kPa at 0.1 and 5 kPa at 0.02")
    func reach() {
        #expect(abs(ValidationTables.refinementReach(threshold: 0.1) - 20_000) < 500)
        #expect(abs(ValidationTables.refinementReach(threshold: 0.02) - 5_000) < 1_000)
        // At 0.005 it follows past 40 m/kg^(1/3), where Kingery–Bulmash gives 2.4 kPa.
        #expect(
            ValidationTables.refinementReach(threshold: 0.005)
                < KingeryBulmash.point(at: 40)!.incidentPressure)
    }

    /// A gauge on the ground of an open 500 t scene, `z` m/kg^(1/3) from the charge.
    private func gaugeBands(z: Float, cells: Float, refine: Int = 1, threshold: Float = 0.1) -> GaugeBands? {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.charge.mass = 500_000
        try? scenario.fitOpenScene(scaledReach: 60)
        let centre = scenario.charge.position
        scenario.gauges = [Gauge("far", at: SIMD3(centre.x + z * Float(cbrt(500_000.0)), centre.y, 0.5))]
        var configuration = SolverConfiguration()
        configuration.refinement = refine
        configuration.refinementLevels = refine > 1 ? 2 : 1
        configuration.refinementThreshold = threshold
        return SceneStanding(
            StandingInputs(scenario: scenario, cellSize: cells, configuration: configuration)
        )
        .gauge("far")
    }

    @Test(
        "Gauges beyond 6 m/kg^(1/3) take the large scenes' bands, and refined ones the cells the shock is on")
    func farGauges() throws {
        // 8 m cells on 500 t, Z = 20: within the 67, 65 and 64% either side.
        let uniform = try #require(gaugeBands(z: 20, cells: 8)?.peak)
        #expect(uniform.low >= 0.64 - 1e-9 && uniform.high <= 0.67 + 1e-9, "\(uniform.low)–\(uniform.high)")
        // 16 m cells refined twice: at 0.1 the shock (6 kPa) is too weak there to be refined, and the
        // peak is the 16 m grid's; at 0.005 it is the 4 m grid's.
        let weak = try #require(gaugeBands(z: 20, cells: 16, refine: 2)?.peak)
        #expect(weak.high < 0.52 && weak.validity.contains("too weak"))
        let followed = try #require(gaugeBands(z: 20, cells: 16, refine: 2, threshold: 0.005)?.peak)
        #expect(followed.low > 0.73 && !followed.validity.contains("too weak"))
        #expect(
            gaugeBands(z: 50, cells: 8)?.peak == nil
                && gaugeBands(z: 50, cells: 8)?.note?.contains("40") == true)
    }
}
