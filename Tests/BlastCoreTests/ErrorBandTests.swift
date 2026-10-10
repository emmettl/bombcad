import Foundation
import Testing
import simd

@testable import BlastCore

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

/// The text under the heading `link` names ("page.md#anchor"), to the next heading as high or
/// higher; the whole page without an anchor. Runs of white space are one space.
private func section(_ link: String) throws -> String {
    let parts = link.split(separator: "#", maxSplits: 1).map(String.init)
    let lines = try String(contentsOf: docs.appending(path: parts[0]), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
    var text = lines[...]
    if parts.count == 2 {
        guard
            let start = lines.firstIndex(where: {
                $0.hasPrefix("#") && anchor($0.drop { $0 == "#" }.drop { $0 == " " }) == parts[1]
            })
        else { return "" }
        let level = lines[start].prefix { $0 == "#" }.count
        let end =
            lines[(start + 1)...].firstIndex {
                $0.hasPrefix("#") && $0.prefix { $0 == "#" }.count <= level
            } ?? lines.endIndex
        text = lines[start..<end]
    }
    return normalised(text.joined(separator: "\n"))
}

private func normalised(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The numbers in `text`, with words for fractions and multiples as their percentages.
private func numbers(_ text: String) -> [Double] {
    var found: [Double] = []
    let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "−", with: "-")
    var current = ""
    for character in cleaned + " " {
        if character.isNumber || (character == "." && !current.isEmpty) {
            current.append(character)
        } else {
            if let value = Double(current.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                found.append(value)
            }
            current = ""
        }
    }
    let words: [String: Double] = [
        "a third": 33, "a half": 50, "twice": 200, "three": 300, "five": 500, "two": 200, "a thirtieth": 3.33,
        "a fiftieth": 2,
    ]
    for (word, value) in words where text.contains(word) { found.append(value) }
    return found
}

/// The rows of the first table under `link` whose header contains `header`, as cells.
private func table(_ link: String, header: String) throws -> [[String]] {
    let parts = link.split(separator: "#", maxSplits: 1).map(String.init)
    let lines = try String(contentsOf: docs.appending(path: parts[0]), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let start = try #require(
        lines.firstIndex { $0.hasPrefix("#") && anchor($0.drop { $0 == "#" }.drop { $0 == " " }) == parts[1] }
    )
    let head = try #require(lines[start...].firstIndex { $0.hasPrefix("|") && $0.contains(header) })
    return lines[(head + 2)...].prefix { $0.hasPrefix("|") }.map {
        $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private func percent(_ cell: String) -> Double? { Double(cell.replacingOccurrences(of: "%", with: "")) }

@Suite struct ErrorBandTests {
    /// Parsed: the Kingery–Bulmash, afterburning and close-in tables are read from the record and
    /// must equal the code's, cell for cell.
    @Test func tablesMirrorTheValidationRecord() throws {
        let kb = "validation.md#kingerybulmash-the-design-practice-standard"
        let mirrored: [(String, String, ValidationTables.Table, Int)] = [
            (kb, "Reference peak | 0.5 m cells", ValidationTables.incidentPeak, 3),
            (kb, "Reference impulse | 0.5 m cells", ValidationTables.incidentImpulse, 2),
            (kb, "Stand-off | Reference peak", ValidationTables.reflectedPeak, 2),
            (kb, "Stand-off | Reference impulse", ValidationTables.reflectedImpulse, 2),
        ]
        for (link, header, code, first) in mirrored {
            let rows = try table(link, header: header)
            #expect(rows.count == ValidationTables.distances.count, "\(header)")
            for grid in 0..<3 {
                let column = rows.map { percent($0[first + grid]) }
                #expect(column == code.byGrid[grid]!.map(Optional.some), "\(header), grid \(grid)")
            }
        }
        // Afterburning and hot air: the refinement table's uniform 0.25 and 0.125 m columns, and the
        // first table's incident impulse with hot air.
        let refined = try table("validation.md#afterburning", header: "0.5 m refined")
        #expect(
            refined.map { percent($0[2]) }
                == ValidationTables.burningIncidentPeak.byGrid[1]!.map(Optional.some))
        #expect(
            refined.map { percent($0[4]) }
                == ValidationTables.burningIncidentPeak.byGrid[2]!.map(Optional.some))
        #expect(
            refined.map { percent($0[6]) }
                == ValidationTables.burningReflectedImpulse.byGrid[1]!.map(Optional.some))
        #expect(
            refined.map { percent($0[8]) }
                == ValidationTables.burningReflectedImpulse.byGrid[2]!.map(Optional.some))
        let burning = try table("validation.md#afterburning", header: "With hot air: incident peak")
        #expect(
            burning.map { percent($0[6]) }
                == ValidationTables.burningIncidentImpulse.byGrid[1]!.map(Optional.some))
        // Close in: four cell sizes, peaks then impulses.
        let close = try table("validation.md#close-in", header: "Z (free air)")
        #expect(close.map { Double($0[0]) } == ValidationTables.closeDistances.map(Optional.some))
        for grid in 0..<4 {
            #expect(
                close.map { percent($0[2 + grid]) }
                    == ValidationTables.closeReflectedPeak.byGrid[grid]!.map(Optional.some))
            #expect(
                close.map { percent($0[7 + grid]) }
                    == ValidationTables.closeReflectedImpulse.byGrid[grid]!.map(Optional.some))
        }
    }

    /// Hand-mirrored: every single figure's quote lies under its heading, and its numbers are the
    /// band's (as a percentage, as "within" its distance from 100%, or as a multiple).
    @Test func figuresQuoteTheRecord() throws {
        for figure in ValidationTables.figures {
            let text = try section(figure.document)
            for quote in figure.quotes {
                #expect(
                    text.contains(normalised(quote)),
                    "\(figure.id): \"\(quote)\" not under \(figure.document)")
            }
            let found = figure.quotes.flatMap(numbers)
            for end in [figure.low, figure.high] {
                let p = end * 100
                let matches = found.contains {
                    abs($0 - p) < 0.6 || abs($0 - abs(p - 100)) < 0.6 || abs($0 * 100 - p) < 0.6
                }
                #expect(matches, "\(figure.id): \(p)% is not in \(figure.quotes)")
            }
        }
        #expect(Set(ValidationTables.figures.map(\.id)).count == ValidationTables.figures.count)
    }

    @Test func readingATableInterpolatesBetweenGridsAndSpansDistances() throws {
        let table = ValidationTables.reflectedImpulse
        let grids = ValidationTables.grids
        let distances = ValidationTables.distances
        // On the 0.25 m grid at 2 m/kg^(1/3): the rows either side, 97–102%.
        let medium = try #require(
            ValidationTables.read(table, grids: grids, distances: distances, cell: grids[1], distance: 2))
        #expect(abs(medium.low - 0.97) < 1e-9 && abs(medium.high - 1.02) < 1e-9 && !medium.scaled)
        // Between 1.5 and 2: just those two rows.
        let between = try #require(
            ValidationTables.read(table, grids: grids, distances: distances, cell: grids[1], distance: 1.7))
        #expect(abs(between.low - 0.97) < 1e-9 && abs(between.high - 1.01) < 1e-9)
        // Halfway between grids in the logarithm: halfway between their values.
        let halfway = try #require(
            ValidationTables.read(
                table, grids: grids, distances: distances, cell: (grids[0] * grids[1]).squareRoot(),
                distance: 1.7))
        #expect(halfway.scaled && abs(halfway.low - (0.88 + 0.97) / 2) < 1e-9)
        // Finer than compared takes the finest; coarser, or beyond the distances, nothing.
        #expect(
            ValidationTables.read(table, grids: grids, distances: distances, cell: grids[2] / 2, distance: 2)?
                .low
                == 1.02)
        #expect(
            ValidationTables.read(table, grids: grids, distances: distances, cell: grids[0] * 2, distance: 2)
                == nil)
        #expect(
            ValidationTables.read(table, grids: grids, distances: distances, cell: grids[1], distance: 8)
                == nil)
    }

    @Test func gaugesTakeTheirOwnBands() throws {
        // 100 kg on the open ground preset at 0.25 m: its gauges are the comparison's own grid.
        let open = SceneStanding(StandingInputs(scenario: ScenarioPreset.openGround.scenario, cellSize: 0.25))
        let gauges = try #require(open.gauges)
        #expect(gauges.count == ScenarioPreset.openGround.scenario.gauges.count)
        for gauge in gauges where (0.75...6).contains(gauge.scaledDistance) {
            #expect(!gauge.onSurface)
            let peak = try #require(gauge.peak)
            #expect(peak.quantity == "Incident peak overpressure" && peak.high <= 0.82 && peak.low >= 0.76)
            #expect(peak.side == "unsafe side" && peak.reads.hasPrefix("reads low"))
            #expect(try #require(gauge.impulse).high < 0.9)
        }
        let impulse = try #require(open[.impulse]?.bands?.first)
        #expect(impulse.quantity == "Impulse at the gauges")

        // Afterburning and hot air switch the incident impulse to its fitted band.
        var config = SolverConfiguration()
        config.afterburning = true
        config.airModel = .thermallyPerfect
        let burning = SceneStanding(
            StandingInputs(
                scenario: ScenarioPreset.openGround.scenario, cellSize: 0.25, configuration: config))
        let far = try #require(burning.gauges?.first { $0.scaledDistance > 1.5 && $0.scaledDistance < 5 })
        #expect(try #require(far.impulse).low >= 0.94)

        // Coarser than any grid: no band, and a reason.
        var small = ScenarioPreset.openGround.scenario
        small.charge.mass = 1
        let coarse = SceneStanding(StandingInputs(scenario: small, cellSize: 0.5))
        #expect(coarse.gauges?.allSatisfy { $0.peak == nil && $0.note != nil } == true)
        #expect(coarse[.peakOverpressure]?.bands?.isEmpty == true)
    }

    @Test func aGaugeOnAWallReadsTheReflectedBand() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        let wall = try #require(scenario.structure?.solids.first)
        scenario.gauges = [Gauge("Face", at: SIMD3(wall.min.x - 0.1, (wall.min.y + wall.max.y) / 2, 1))]
        let standing = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25))
        let face = try #require(standing.gauge("Face"))
        #expect(face.onSurface)
        #expect(face.peak?.quantity == "Reflected peak overpressure")
    }

    @Test func structuresTakeBandsByRegimeMeshAndMaterial() throws {
        let wall = SceneStanding(StandingInputs(scenario: ScenarioPreset.blastWall.scenario, cellSize: 0.25))
        let deflection = try #require(wall.band(.peakDeflection))
        #expect(deflection.ratio == "105–115%" && deflection.reads == "reads high: too flexible")
        let expected = deflection.expected(115)
        #expect(abs(expected.lowerBound - 100) < 1e-9 && abs(expected.upperBound - 115 / 1.05) < 1e-9)
        #expect(wall[.structuralResponse]?.regimes?.isEmpty == false)

        // An option the slab was not compared with leaves it without a band.
        var pressed = ScenarioPreset.blastWall.scenario
        pressed.structure?.pressedInterlock = true
        let standing = SceneStanding(StandingInputs(scenario: pressed, cellSize: 0.25))
        #expect(standing.band(.peakDeflection) == nil)
        #expect(standing[.structuralResponse]?.unbanded?.first?.contains("Pressed interlock") == true)
        let advice = try #require(
            standing[.structuralResponse]?.regimes?.first { $0.option == "Pressed interlock" })
        #expect(advice.suits == false && advice.suggestion != nil)

        // Close in, with a small charge: Wu's band, the model too stiff.
        var close = ScenarioPreset.blastWall.scenario
        let solid = try #require(close.structure?.solids.first)
        close.charge = Charge(
            mass: 0.5, position: SIMD3(solid.min.x - 0.3, (solid.min.y + solid.max.y) / 2, 0.5))
        let near = SceneStanding(StandingInputs(scenario: close, cellSize: 0.25))
        let wu = try #require(near.band(.peakDeflection))
        #expect(wu.ratio == "40–70%" && wu.side == "unsafe side")
        #expect(near[.structuralResponse]?.regimes?.contains { $0.option == "Fragments removed" } == true)
    }

    @Test func terrainAndDeflagrationGiveNoKingeryBulmashBand() throws {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.terrain = Terrain.hill(
            domain: scenario.domainSize, spacing: 1, centre: SIMD2(20, 32), height: 4, radius: 6)
        let hilly = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25))
        #expect(
            hilly.gauges?.allSatisfy { $0.peak == nil && $0.note?.contains("flat ground") == true } == true)
    }

    @Test func confinedScenesAreAdvisedOnAfterburning() throws {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.reflectiveFaces = .all
        let room = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25))
        let advice = try #require(room[.impulse]?.regimes?.first)
        #expect(
            advice.regime == "confined" && advice.suits == false && advice.suggestion?.contains("98%") == true
        )
        #expect(room.band(.gasPressure)?.ratio == "48–114%")
    }

    @Test func standingsWithoutBandsStillDecode() throws {
        let current = SceneStanding(
            StandingInputs(scenario: ScenarioPreset.blastWall.scenario, cellSize: 0.25))
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["gauges"] = nil
        object["results"] = (object["results"] as! [[String: Any]]).map {
            var result = $0
            for key in ["bands", "unbanded", "regimes"] { result[key] = nil }
            return result
        }
        let old = try JSONDecoder().decode(
            SceneStanding.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.gauges == nil && old.results.allSatisfy { $0.bands == nil && $0.regimes == nil })
        #expect(try JSONDecoder().decode(SceneStanding.self, from: JSONEncoder().encode(current)) == current)
    }
}
