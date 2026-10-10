import Foundation
import Testing
import simd

@testable import BlastCore

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
        VentPanel(box: Box(min: .zero, max: .one), releasePressure: 1000),
    ]
}

/// Inputs for `scenario` on `cellSize` air with `change` made to them.
private func standing(
    _ scenario: Scenario = ScenarioPreset.streetCanyon.scenario, cellSize: Float = 0.25,
    _ change: (inout StandingInputs) -> Void = { _ in }
) -> SceneStanding {
    var inputs = StandingInputs(scenario: scenario, cellSize: cellSize)
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

@Suite struct EvidentialStandingTests {
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
        #expect(wall[.structuralResponse]?.level == .measured)
        #expect(wall[.structuralDamage]?.level == .approximation)
        #expect(wall.unsupported.contains { $0.contains("Collapse has never been compared") })
        #expect(standing(ScenarioPreset.openGround.scenario)[.structuralResponse] == nil)
    }

    @Test func afterburningChangesTheImpulsesStanding() throws {
        let plain = try #require(standing()[.impulse])
        let burning = try #require(
            standing {
                $0.configuration.afterburning = true
                $0.configuration.airModel = .thermallyPerfect
            }[.impulse])
        #expect(plain.level == .measured && burning.level == .measured)
        #expect(plain.summary.contains("13–22% low"))
        #expect(burning.summary.contains("94–99%") && burning.summary.contains("fitted"))
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
        #expect(pressed[.impulse]?.level == .measured)

        scenario = ScenarioPreset.blastWall.scenario
        scenario.structure?.elementKind = .shell
        #expect(standing(scenario)[.structuralResponse]?.level == .measured)

        scenario = ScenarioPreset.openGround.scenario
        let flat = standing(scenario)
        scenario.terrain = Terrain.hill(
            domain: scenario.domainSize, spacing: 1, centre: SIMD2(20, 32), height: 4, radius: 6)
        let hilly = standing(scenario)
        #expect(flat[.impulse]?.level == .measured && hilly[.impulse]?.level == .approximation)
        #expect(hilly[.impulse]?.evidence.contains { $0.document.hasPrefix("terrain.md") } == true)
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
                $0.contains("measured agreement against approximation")
            })
    }
}
