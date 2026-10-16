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
        "a fiftieth": 2, "a fifth": 20, "a sixth": 16.7, "a seventh": 14.3, "five and a half": 550,
        "a tenth": 10,
        "a quarter": 25,
    ]
    for (word, value) in words where text.contains(word) { found.append(value) }
    return found
}

/// The rows of the first table under `link` whose header contains `header`, as cells; after the
/// first line under it that begins with `after`, where given.
private func table(_ link: String, header: String, after: String? = nil) throws -> [[String]] {
    let parts = link.split(separator: "#", maxSplits: 1).map(String.init)
    let lines = try String(contentsOf: docs.appending(path: parts[0]), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let start = try #require(
        lines.firstIndex { $0.hasPrefix("#") && anchor($0.drop { $0 == "#" }.drop { $0 == " " }) == parts[1] }
    )
    let from =
        try after.map { prefix in try #require(lines[start...].firstIndex { $0.hasPrefix(prefix) }) } ?? start
    let head = try #require(lines[from...].firstIndex { $0.hasPrefix("|") && $0.contains(header) })
    return lines[(head + 2)...].prefix { $0.hasPrefix("|") }.map {
        $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private func percent(_ cell: String) -> Double? { Double(cell.replacingOccurrences(of: "%", with: "")) }

@Suite(.timeLimit(.minutes(120))) struct ErrorBandTests {
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
        // Today's defaults, afterburning, hot air and far-field faces: four quantities on three grids.
        let burning = try table(ValidationTables.burningDocument, header: "Incident peak: 0.5 m")
        #expect(burning.count == ValidationTables.distances.count)
        for (first, code) in [
            (2, ValidationTables.burningIncidentPeak), (5, ValidationTables.burningIncidentImpulse),
            (8, ValidationTables.burningReflectedPeak), (11, ValidationTables.burningReflectedImpulse),
        ] {
            for grid in 0..<3 {
                #expect(
                    burning.map { percent($0[first + grid]) } == code.byGrid[grid]!.map(Optional.some),
                    "burning column \(first + grid)")
            }
        }
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
        // The same on today's air, the second table.
        let today = try table(
            "validation.md#close-in", header: "Z (free air)", after: "On today's air (afterburning")
        #expect(today.map { Double($0[0]) } == ValidationTables.closeDistances.map(Optional.some))
        for grid in 0..<4 {
            #expect(
                today.map { percent($0[2 + grid]) }
                    == ValidationTables.closeBurningReflectedPeak.byGrid[grid]!.map(Optional.some))
            #expect(
                today.map { percent($0[7 + grid]) }
                    == ValidationTables.closeBurningReflectedImpulse.byGrid[grid]!.map(Optional.some))
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
        // Results after failure across roundings: each row under its heading, holding its values.
        for rounding in ValidationTables.roundings {
            let text = try section(rounding.document)
            #expect(
                text.contains(normalised(rounding.quote)),
                "\(rounding.id): row not under \(rounding.document)")
            let found = numbers(rounding.quote)
            for value in rounding.values {
                #expect(found.contains { abs($0 - value) < 1e-9 }, "\(rounding.id): \(value) not in its row")
            }
        }
        // The references' own scatter: each quote under its heading, holding the figure.
        for scatter in ValidationTables.scatters {
            let text = try section(scatter.document)
            #expect(
                text.contains(normalised(scatter.quote)), "\(scatter.id): quote not under \(scatter.document)"
            )
            #expect(
                numbers(scatter.quote).contains { abs($0 - scatter.sigma * 100) < 0.05 },
                "\(scatter.id): \(scatter.sigma) is not in \"\(scatter.quote)\"")
        }
        // The ensemble's spreads: each row under its heading, holding "mean, coefficient%".
        let spreads = try section(ValidationTables.spreadDocument)
        for spread in ValidationTables.spreads {
            #expect(
                spreads.contains(normalised(spread.quote)), "\(spread.id): row not in the ensemble's table")
            #expect(
                spread.quote.contains(String(format: ", %.0f%% |", spread.coefficient * 100)),
                "\(spread.id): \(spread.coefficient) is not the row's spread")
        }
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

    /// Close in, on today's air: the reruns' own table, and afterburning alone none.
    @Test func closeInGaugesOnTodaysAir() throws {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.charge = Charge(mass: 1, position: SIMD3(10, 10, 0.5))
        scenario.gauges = [Gauge("Beneath", at: SIMD3(10, 10, 0.01))]
        var config = SolverConfiguration()
        config.afterburning = true
        config.airModel = .thermallyPerfect
        let today = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.01, configuration: config))
        let beneath = try #require(today.gauge("Beneath"))
        let peak = try #require(beneath.peak)
        #expect(peak.document == "validation.md#close-in" && peak.check.contains("afterburning"))
        #expect(peak.low >= 0.64 - 1e-9 && peak.high <= 0.90 + 1e-9)
        config.airModel = .idealGas
        let alone = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.01, configuration: config))
        #expect(alone.gauge("Beneath")?.peak == nil && alone.gauge("Beneath")?.note != nil)
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
        #expect(far.impulse?.document == ValidationTables.burningDocument)

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
        // Today's defaults have their own reflected peaks too.
        var burns = SolverConfiguration()
        burns.afterburning = true
        burns.airModel = .thermallyPerfect
        let hot = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25, configuration: burns))
        #expect(hot.gauge("Face")?.peak?.document == ValidationTables.burningDocument)
        #expect(face.peak?.inputSpread == 0.02 && face.impulse?.inputSpread == 0.01)
        #expect(face.peak?.referenceScatter == 0.08 && face.impulse?.referenceScatter == 0.08)
        // Under-resolved peaks lie outside the tests' scatter; the difference is the model's.
        #expect(
            face.peak?.withinReference == false && face.peak?.againstReference?.hasPrefix("Outside") == true)
        // Behind the wall, shielded: not compared.
        scenario.gauges = [Gauge("Behind", at: SIMD3(wall.max.x + 0.1, (wall.min.y + wall.max.y) / 2, 1))]
        let behind = try #require(
            SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25)).gauge("Behind"))
        #expect(behind.peak == nil && behind.note?.hasPrefix("Shielded") == true)
    }

    @Test func structuresTakeBandsByRegimeMeshAndMaterial() throws {
        let wall = SceneStanding(StandingInputs(scenario: ScenarioPreset.blastWall.scenario, cellSize: 0.25))
        let deflection = try #require(wall.band(.peakDeflection))
        #expect(deflection.inputSpread == 0.12)
        #expect(deflection.derivedMesh?.hasPrefix("4 to 32 elements through") == true)
        // Too flexible under the contest's load, too stiff under its lower shot: either way.
        // Up to the 119% the slab's peak rises towards with the mesh.
        #expect(deflection.ratio == "79–119%" && deflection.reads == "reads either way")
        #expect(deflection.referenceScatter == 0.03)
        let expected = deflection.expected(115)
        #expect(abs(expected.lowerBound - 115 / 1.19) < 1e-9 && abs(expected.upperBound - 115 / 0.79) < 1e-9)
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
        // Wu's band was derived on 8 elements through; this wall has 4, so it does not apply.
        #expect(near.band(.peakDeflection) == nil)
        #expect(near[.structuralResponse]?.unbanded?.contains { $0.contains("not applicable on 4") } == true)
        // On 8 elements through it applies, with its mesh recorded.
        var eight = close
        eight.structure?.elementSize = (solid.max.x - solid.min.x) / 8
        let wu = try #require(
            SceneStanding(StandingInputs(scenario: eight, cellSize: 0.25)).band(.peakDeflection))
        #expect(
            wu.ratio == "40–70%" && wu.side == "unsafe side" && wu.derivedMesh == "8 elements through only")
        #expect(near[.structuralResponse]?.regimes?.contains { $0.option == "Fragments removed" } == true)

        // In the far field but as near as blind test 2's open-air slabs: the contest slab's band is
        // withheld, and the standing says why.
        var blind = ScenarioPreset.blastWall.scenario
        blind.charge = Charge(
            mass: 2.7, position: SIMD3(solid.min.x - 1.2 * cbrt(2.7), (solid.min.y + solid.max.y) / 2, 0.5))
        let open = SceneStanding(StandingInputs(scenario: blind, cellSize: 0.25))
        #expect(open.band(.peakDeflection) == nil)
        #expect(
            open[.structuralResponse]?.unbanded?.contains { $0.contains("read 10–25% of meters") }
                == true)
        #expect(wall[.structuralResponse]?.resolution.contains { $0.contains("keep the air awake") } == true)

        // In contact, on 12 elements through: the debris band, one draw among roundings, widened by
        // SN131's far face (15.2–18.7 m/s).
        var contact = ScenarioPreset.blastWall.scenario
        contact.charge = Charge(
            mass: 1, position: SIMD3(solid.min.x - 0.1, (solid.min.y + solid.max.y) / 2, 0.5))
        contact.structure?.elementSize = (solid.max.x - solid.min.x) / 12
        let debris = try #require(
            SceneStanding(StandingInputs(scenario: contact, cellSize: 0.25)).band(.debrisSpeed))
        #expect(abs((debris.roundingSpread ?? 0) - 3.5 / 33.9) < 1e-9)
        #expect(debris.expectedWithInputs(100) != debris.expected(100))
        // Derived again on today's air, with its own roundings (SN142's 61.5–106.3 m/s).
        var burns = SolverConfiguration()
        burns.afterburning = true
        burns.airModel = .thermallyPerfect
        let burning = SceneStanding(StandingInputs(scenario: contact, cellSize: 0.25, configuration: burns))
        let today = try #require(burning.band(.debrisSpeed))
        #expect(today.ratio == "88–182%")
        #expect(abs((today.roundingSpread ?? 0) - 44.8 / 167.8) < 1e-9)
        // Afterburning without hot air was compared on neither.
        burns.airModel = .idealGas
        let alone = SceneStanding(StandingInputs(scenario: contact, cellSize: 0.25, configuration: burns))
        #expect(alone.band(.debrisSpeed) == nil)
    }

    /// Mirrored: the convergence study's OA1 row holds every mesh's value and the measurement.
    /// The fireball's radiation and Church's clouds were compared on today's air, afterburning and
    /// hot air: each band holds only on the air it came from.
    @Test func radiationAndCloudFollowTheAirTheyWereComparedOn() throws {
        func standing(afterburning: Bool, hotAir: Bool) -> SceneStanding {
            var config = SolverConfiguration()
            config.afterburning = afterburning
            config.airModel = hotAir ? .thermallyPerfect : .idealGas
            return SceneStanding(
                StandingInputs(
                    scenario: ScenarioPreset.streetCanyon.scenario, cellSize: 0.25, configuration: config,
                    thermal: ThermalSpec(), cloud: CloudSpec()))
        }
        let today = standing(afterburning: true, hotAir: true)
        #expect(today.band(.radiatedEnergy) != nil && today.band(.cloudTop) != nil)
        let alone = standing(afterburning: true, hotAir: false)
        #expect(alone.band(.radiatedEnergy) == nil && alone.band(.cloudTop) == nil)
        #expect(alone[.cloud]?.unbanded?.contains { $0.contains("afterburning alone") } == true)
        let ideal = standing(afterburning: false, hotAir: false)
        #expect(ideal.band(.radiatedEnergy) == nil && ideal.band(.cloudTop) == nil)
    }

    @Test func meshSeriesQuoteTheStudy() throws {
        let series = ValidationTables.oa1
        let text = try section(series.document)
        #expect(text.contains(normalised(series.quote)), "OA1's row is not under \(series.document)")
        let found = numbers(series.quote)
        #expect(found.contains(series.measured))
        for (through, value) in series.byMesh {
            #expect(series.quote.contains("\(through): \(Int(value))"), "\(through): \(value) not in the row")
        }
        // On the calibrated mesh the band spans the meshes either side: 104% to 132%.
        let band = try #require(series.band(on: series.calibrated))
        #expect(abs(band.low - 344 / 332.0) < 1e-9 && abs(band.high - 437 / 332.0) < 1e-9)
        #expect(series.band(on: 60) == nil && series.band(on: 8) == nil)
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
        #expect(room.band(.gasPressure)?.withinReference == false)
        var config = SolverConfiguration()
        config.afterburning = true
        config.airModel = .thermallyPerfect
        let hot = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25, configuration: config))
        // 98–108% against the rooms' 11%: inside, and so no better than the tests.
        #expect(hot.band(.gasPressure)?.withinReference == true)
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

    @Test func theConfinedRegimesDefaultsAreReported() throws {
        let chamber = SceneStanding(
            StandingInputs(scenario: ScenarioPreset.internalExplosion.scenario, cellSize: 0.25))
        let advice = try #require(
            chamber[.structuralResponse]?.regimes?.first { $0.option == "Pressed interlock" })
        #expect(
            advice.regime == "confined" && advice.suits == true && advice.note.hasPrefix("On by the confined")
        )
        // The regime's own default is no user option, so it does not take the band away.
        #expect(
            chamber[.structuralResponse]?.unbanded?.contains { $0.contains("Pressed interlock") } == false)
    }
}
