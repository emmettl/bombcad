import Foundation
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// A default value of every input type the standing reads. A type that gains a stored property
/// fails `everyInputHasAStandingEntry` until `StandingTable.fields` says what it is.
private var inputSamples: [Any] {
    [
        ScenarioPreset.streetCanyon.scenario,
        Charge(mass: 1, position: .zero),
        SolverConfiguration(),
        StructureModel(solids: [], elementSize: 0.1),
        StructureMaterial.reinforcedConcrete,
        Anchorage.resting(),
        ThermalSpec(),
        SurfaceHeatingSpec(),
        CloudSpec(),
        FragmentSpec(),
        GroundShockSpec(),
        GroundSoil(),
        Terrain(spacing: 1, columns: 2, rows: 2, heights: [0, 0, 0, 1]),
        Deflagration(region: Box(min: .zero, max: .one), ignition: .zero),
        FlameAcceleration(),
        FlameTurbulence(),
        VentPanel(box: Box(min: .zero, max: .one), releasePressure: 1000),
        EnvelopeSource(objectID: UUID(), kind: .map, detail: ""),
        EnvelopeConstruction.assumed(objectID: UUID()),
        StandingInputs(scenario: ScenarioPreset.streetCanyon.scenario, cellSize: 0.25),
    ]
}

/// Inputs for `scenario` on `cellSize` air with `change` made to them.
private func standing(
    _ scenario: Scenario = ScenarioPreset.streetCanyon.scenario, cellSize: Float = 0.25,
    _ change: (inout StandingInputs) -> Void = { _ in }
) -> SceneStanding {
    var inputs = StandingInputs(scenario: scenario, cellSize: cellSize)
    // As the app runs it, with far-field faces whether or not it burns.
    inputs.configuration.openFaces = SolverConfiguration.recommended.openFaces
    change(&inputs)
    return SceneStanding(inputs)
}

/// Every preset on every grid, with and without the options the app offers and the models run
/// alongside it.
private var sampleStandings: [SceneStanding] {
    ScenarioPreset.allCases.flatMap { preset in
        [0.5, 0.25, 0.125].flatMap { (cell: Float) in
            [false, true].map { detailed in
                standing(preset.scenario, cellSize: cell) { inputs in
                    inputs.configuration.afterburning = detailed
                    inputs.configuration.airModel = detailed ? .thermallyPerfect : .idealGas
                    inputs.configuration.refinement = detailed ? 2 : 1
                    inputs.thermal = detailed ? ThermalSpec() : nil
                    inputs.cloud = detailed ? CloudSpec() : nil
                    inputs.fragments = detailed ? FragmentSpec() : nil
                    inputs.groundShock = detailed ? GroundShockSpec() : nil
                }
            }
        }
    }
}

/// GitHub's anchor for a heading: lower case, punctuation dropped, spaces as hyphens.
private func anchor(_ heading: String) -> String {
    String(
        heading.lowercased().unicodeScalars.compactMap { scalar -> Character? in
            if scalar == " " { return "-" }
            if scalar == "-" || scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return nil
        })
}

private let docs = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "docs")

@Suite(.timeLimit(.minutes(120))) struct EvidentialStandingTests {
    @Test func everyInputHasAStandingEntry() {
        let names = inputSamples.flatMap(StandingTable.fieldNames(of:))
        let missing = names.filter { StandingTable.fields[$0] == nil }
        #expect(
            missing.isEmpty,
            "No standing entry for \(missing.joined(separator: ", ")): say in StandingTable.fields whether each is a model option (and add its entry), an input or a numerical control"
        )
        let stale = Set(StandingTable.fields.keys).subtracting(names)
        #expect(
            stale.isEmpty, "StandingTable.fields names properties that no longer exist: \(stale.sorted())")
    }

    @Test func aDeflagrationDoesNotQuoteTheChargesComparisons() {
        let scene = standing(ScenarioPreset.ventedGasRoom.scenario, cellSize: 0.125)
        for kind in [ResultKind.peakOverpressure, .impulse] {
            let result = scene.results.first { $0.kind == kind }
            #expect(result?.level == .illustrative)
            #expect(result?.evidence.contains { $0.check.contains("Kingery") } == false)
            #expect(result?.evidence.contains { $0.document.hasPrefix("deflagration.md") } == true)
        }
    }

    /// Hydrogen takes its own vented band; town gas, never vented in a comparison, none.
    @Test func aDeflagrationsBandFollowsItsFuel() throws {
        func scene(_ gas: FlammableGas) -> SceneStanding {
            var scenario = ScenarioPreset.ventedGasRoom.scenario
            scenario.deflagration?.gas = gas
            return standing(scenario, cellSize: 0.125)
        }
        let methane = scene(.methane)[.peakOverpressure]?.bands ?? []
        #expect(methane.contains { $0.check.contains("Bauwens et al.'s vented") })
        let hydrogen = scene(.hydrogen)
        // Either way: FM Global's chamber on the safe side, HySEA's roof-vented containers on the unsafe.
        #expect((hydrogen[.peakOverpressure]?.bands ?? []).map(\.ratio) == ["19–296%"])
        #expect(hydrogen[.peakOverpressure]?.summary.hasPrefix("Lean hydrogen") == true)
        let town = scene(.townGas)
        #expect((town[.peakOverpressure]?.bands ?? []).isEmpty)
        #expect(town[.peakOverpressure]?.unbanded?.contains { $0.contains("town gas") } == true)
    }

    /// The process plant is no vented room, a gas explosion is no TNT fireball, and a sheeted
    /// warehouse has no concrete walls: each takes only the bands that fit it.
    @Test func samplesTakeOnlyTheBandsThatFitThem() throws {
        func scene(_ preset: ScenarioPreset) -> SceneStanding {
            var inputs = StandingInputs(
                // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
                scenario: preset.scenario, cellSize: 0.25, configuration: .recommended.balloonStart)
            inputs.thermal = ThermalSpec()
            inputs.cloud = CloudSpec()
            return SceneStanding(inputs)
        }
        let plant = scene(.processPlantExplosion)
        #expect((plant[.peakOverpressure]?.bands ?? []).isEmpty)
        #expect(plant[.peakOverpressure]?.unbanded?.contains { $0.contains("vented room") } == true)
        #expect((plant[.impulse]?.bands ?? []).isEmpty)
        #expect((plant[.thermal]?.bands ?? []).isEmpty && (plant[.cloud]?.bands ?? []).isEmpty)
        let room = scene(.ventedGasRoom)
        #expect(!(room[.peakOverpressure]?.bands ?? []).isEmpty && (room[.impulse]?.bands ?? []).isEmpty)
        let warehouse = scene(.portalWarehouse)
        let envelope = warehouse[.envelopeDamage]
        #expect(envelope?.bands?.contains { $0.quantity.hasPrefix("Concrete") } != true)
        #expect(envelope?.unbanded?.contains { $0.hasPrefix("Profiled steel sheeting") } == true)
        let office = scene(.officeTower)
        #expect(office[.envelopeDamage]?.bands?.contains { $0.quantity == "When a pane breaks" } == true)
    }

    /// A structure whose open faces are too near carries the scene's own warning in its standing.
    @Test func tightOpenFacesAreSaidBesideTheStructure() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        let wall = try #require(scenario.structure?.solids.first)
        // Bring the top down to just over the wall: a face far nearer than 4 m/kg^(1/3).
        scenario.domainSize.z = wall.max.z + 0.5
        let note = try #require(scenario.tightFacesNote)
        let tight = standing(scenario)
        #expect(tight[.structuralResponse]?.resolution.contains { $0.hasPrefix(note) } == true)
        var open = ScenarioPreset.blastWall.scenario
        open.domainSize *= 4
        if open.tightFacesNote == nil {
            #expect(
                standing(open)[.structuralResponse]?.resolution.contains { $0.contains("Open faces near") }
                    == false)
        }
    }

    @Test func everyOptionIsSetBySomeInput() {
        let reached = Set(
            StandingTable.fields.values.flatMap { field -> [ModelOption] in
                if case .option(let options) = field { return options }
                return []
            })
        let unreached = ModelOption.allCases.filter { !reached.contains($0) }
        #expect(unreached.isEmpty, "No input sets \(unreached)")
        for option in ModelOption.allCases {
            let entry = StandingTable.entry(for: option)
            #expect(!entry.title.isEmpty && !entry.note.isEmpty && !entry.affects.isEmpty, "\(option)")
        }
    }

    @Test func linksReachHeadingsInTheDocs() throws {
        var links = Set(ModelOption.allCases.map { StandingTable.entry(for: $0).document })
        for scene in sampleStandings {
            for result in scene.results {
                links.formUnion(result.documents)
                links.formUnion(result.evidence.map(\.document))
            }
        }
        for link in links.sorted() {
            let parts = link.split(separator: "#", maxSplits: 1).map(String.init)
            let file = docs.appending(path: parts[0])
            let text = try String(contentsOf: file, encoding: .utf8)
            guard parts.count == 2 else { continue }
            let anchors = text.split(separator: "\n").filter { $0.hasPrefix("#") }.map {
                anchor($0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            }
            #expect(anchors.contains(parts[1]), "\(link) has no such heading")
        }
    }

    @Test func eachPresetHasAStandingForWhatItProduces() throws {
        for scene in sampleStandings {
            #expect(scene[.peakOverpressure] != nil && scene[.impulse] != nil)
            for result in scene.results {
                #expect(!result.summary.isEmpty)
            }
        }
        let wall = standing(ScenarioPreset.blastWall.scenario)
        #expect(wall[.structuralResponse]?.level == .compared)
        #expect(wall[.structuralDamage]?.level == .approximation)
        #expect(wall.unsupported.contains { $0.contains("Collapse compared once, blind, and missed") })
        #expect(standing(ScenarioPreset.openGround.scenario)[.structuralResponse] == nil)
    }

    @Test func afterburningChangesTheImpulsesStanding() throws {
        let plain = try #require(standing()[.impulse])
        let burning = try #require(
            standing {
                $0.configuration.afterburning = true
                $0.configuration.airModel = .thermallyPerfect
            }[.impulse])
        #expect(plain.level == .compared && burning.level == .compared)
        #expect(plain.summary.contains("13–22% low"))
        // Read from today's tables, on whichever grid the street's air matches.
        let spans = (0..<3).map {
            ValidationTables.span(ValidationTables.burningIncidentImpulse, grid: $0, from: 1)
        }
        #expect(spans.contains { burning.summary.contains($0) } && burning.summary.contains("fitted"))
        #expect(burning.options == ["Afterburning", "Hot air"])
        #expect(plain.options.isEmpty)
    }

    @Test func refinementCountsAsTheFinerGrid() throws {
        let coarse = try #require(standing(cellSize: 0.5)[.peakOverpressure])
        let refined = try #require(
            standing(cellSize: 0.5) { $0.configuration.refinement = 2 }[.peakOverpressure])
        let medium = try #require(standing(cellSize: 0.25)[.peakOverpressure])
        #expect(refined.evidence.first == medium.evidence.first)
        #expect(coarse.evidence.first != medium.evidence.first)
        #expect(refined.options == ["Shock refinement"])
    }

    @Test func coarseCellsForASmallChargeAreAnApproximation() throws {
        var scenario = ScenarioPreset.streetCanyon.scenario
        scenario.charge.mass = 1
        let scene = standing(scenario, cellSize: 0.5)
        #expect(scene[.peakOverpressure]?.level == .approximation)
        #expect(scene.resolution.contains { $0.contains("coarser than any grid compared") })
    }

    @Test func closeInLoadingAsksForFinerAir() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        let wall = try #require(scenario.structure?.solids.first)
        scenario.charge.position = SIMD3(wall.min.x - 0.5, (wall.min.y + wall.max.y) / 2, 0.5)
        let scene = standing(scenario)
        #expect(scene.resolution.contains { $0.contains("Close-in loading needs fine or twice-refined air") })
        #expect(scene.resolution.contains { $0.contains("Spall") })
        #expect(scene[.structuralResponse]?.level == .approximation)
    }

    @Test func optionsCapTheResultsTheyTouch() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.structure?.pressedInterlock = true
        let pressed = standing(scenario)
        #expect(pressed[.structuralResponse]?.level == .approximation)
        #expect(pressed[.structuralResponse]?.options == ["Pressed interlock"])
        #expect(pressed[.impulse]?.level == .compared)

        scenario = ScenarioPreset.blastWall.scenario
        scenario.structure?.elementKind = .shell
        #expect(standing(scenario)[.structuralResponse]?.level == .compared)

        scenario = ScenarioPreset.openGround.scenario
        let flat = standing(scenario)
        scenario.terrain = Terrain.hill(
            domain: scenario.domainSize, spacing: 1, centre: SIMD2(20, 32), height: 4, radius: 6)
        let hilly = standing(scenario)
        #expect(flat[.impulse]?.level == .compared && hilly[.impulse]?.level == .approximation)
        #expect(hilly[.impulse]?.evidence.contains { $0.document.hasPrefix("terrain.md") } == true)
        // Cut cells by default, refined or not; the staircase when chosen.
        #expect(hilly[.impulse]?.options.contains("Terrain as a staircase") == false)
        #expect(hilly[.impulse]?.evidence.contains { $0.document == "terrain.md#cut-cells" } == true)
        let twice = standing(scenario) {
            $0.configuration.refinement = 2
            $0.configuration.refinementLevels = 2
        }
        #expect(twice[.impulse]?.options.contains("Terrain as a staircase") == false)
        let staircase = standing(scenario) { $0.configuration.terrainCutCells = false }
        #expect(staircase[.impulse]?.options.contains("Terrain as a staircase") == true)
        #expect(staircase[.impulse]?.evidence.contains { $0.document == "terrain.md#cut-cells" } == false)
        scenario.terrain = Terrain.flat(domain: scenario.domainSize, spacing: 1)
        #expect(standing(scenario) == flat)

        scenario = ScenarioPreset.openGround.scenario
        scenario.rigidCars = [try RigidCarDefinition.saloon(position: SIMD3(10, 10, 0))]
        #expect(standing(scenario)[.freestandingMotion]?.level == .illustrative)
    }

    @Test func modelsRunAlongsideAreIllustrative() {
        let scene = standing {
            $0.thermal = ThermalSpec()
            $0.cloud = CloudSpec()
            $0.fragments = FragmentSpec()
            $0.groundShock = GroundShockSpec()
        }
        for kind in [ResultKind.thermal, .surfaceHeating, .cloud, .fragments, .groundShock] {
            #expect(scene[kind]?.level == .illustrative, "\(kind)")
        }
        #expect(scene[.thermal]?.assumptions.contains { $0.contains("Without afterburning") } == true)
    }

    @Test func standingsRoundTripAndCompare() throws {
        let plain = standing()
        let data = try JSONEncoder().encode(plain)
        #expect(try JSONDecoder().decode(SceneStanding.self, from: data) == plain)
        #expect(plain.differences(from: plain).isEmpty)
        let burning = standing { $0.configuration.afterburning = true }
        let differences = plain.differences(from: burning)
        #expect(differences.contains { $0.hasPrefix("Impulse") })
        let coarse = standing(cellSize: 2)
        #expect(
            plain.differences(from: coarse).contains {
                $0.contains("compared with measurement against approximation")
            })
    }

    @Test func levelsRecordedAsMeasuredStillRead() throws {
        // Standings recorded before 11 October 2026 call the top level "measured".
        let old = try JSONDecoder().decode(
            [EvidenceLevel].self, from: Data(#"["measured", "verified"]"#.utf8))
        #expect(old == [.compared, .verified])
        #expect(
            String(decoding: try JSONEncoder().encode(EvidenceLevel.compared), as: UTF8.self)
                == #""compared""#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EvidenceLevel.self, from: Data(#""agreed""#.utf8))
        }
    }

    /// The levels' names as the code gives them are the docs': the standing page lists each, and
    /// no document but the review that asked for the change still says "measured agreement".
    @Test func theDocsNameTheLevelsAsTheCodeDoes() throws {
        let root = docs.deletingLastPathComponent()
        let standingPage = try String(contentsOf: docs.appending(path: "standing.md"), encoding: .utf8)
        for level in EvidenceLevel.allCases {
            #expect(standingPage.contains("| \(level.title) |"), "standing.md does not list \(level.title)")
        }
        let pages = try FileManager.default.contentsOfDirectory(atPath: docs.path)
            .filter { $0.hasSuffix(".md") && $0 != "validation-review.md" }.map { docs.appending(path: $0) }
        for page in pages + [
            root.appending(path: "README.md"), root.appending(path: "Sources/BombCAD/StandingViews.swift"),
        ] {
            let text = try String(contentsOf: page, encoding: .utf8).lowercased()
            #expect(
                !text.contains("measured agreement"),
                "\(page.lastPathComponent) still says measured agreement")
        }
    }
}
