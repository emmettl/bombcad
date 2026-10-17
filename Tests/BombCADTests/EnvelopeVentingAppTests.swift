import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

/// "Vent broken glazing": envelopes' panes opening in the air in the app and headless runs.
@MainActor @Suite("Envelope venting in the app", .serialized, .hangLimit)
struct EnvelopeVentingAppTests {
    /// A walled 6 m square with one window glazed by a pane in a cut opening, 5 kg 5 m off its
    /// glazed wall.
    func document(vented: Bool) throws -> ProjectDocument {
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(16, 20, 6), boxes: [],
            charge: Charge(mass: 5, position: SIMD3(7, 2, 1)))
        let (x, y): (Float, Float) = (4, 7)
        let solids = [
            Box(min: SIMD3(x, y, 0), max: SIMD3(x + 6, y + 0.2, 3)),
            Box(min: SIMD3(x, y + 5.8, 0), max: SIMD3(x + 6, y + 6, 3)),
            Box(min: SIMD3(x, y + 0.2, 0), max: SIMD3(x + 0.2, y + 5.8, 3)),
            Box(min: SIMD3(x + 5.8, y + 0.2, 0), max: SIMD3(x + 6, y + 5.8, 3)),
            Box(min: SIMD3(x, y, 3), max: SIMD3(x + 6, y + 6, 3.2)),
        ]
        let window = Box(min: SIMD3(x + 2.25, y, 1), max: SIMD3(x + 3.75, y + 0.2, 2.25))
        let pane = Box(min: SIMD3(x + 2.25, y + 0.097, 1), max: SIMD3(x + 3.75, y + 0.103, 2.25))
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: solids, openings: [window], panes: [pane]), name: "Glazed building")
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "medium"
        document.runSettings?.duration = 0.03
        document.runSettings?.ventsGlazing = vented ? true : nil
        return document
    }

    @Test("Venting is saved when on over glazed envelopes, left out otherwise, and changes the fingerprint")
    func saved() throws {
        let model = SimulationModel(document: try document(vented: false))
        model.settings.ventsGlazing = true
        let snapshot = ProjectDocument(model: model)
        #expect(snapshot.runSettings?.ventsGlazing == true)
        model.settings.ventsGlazing = false
        model.open(try ProjectDocument(archive: snapshot.makeArchive()))
        #expect(model.settings.ventsGlazing)
        let off = try document(vented: false)
        #expect(
            !String(decoding: try JSONEncoder().encode(off.runSettings!), as: UTF8.self).contains(
                "ventsGlazing"))
        #expect(
            try SavedSimulationRun.fingerprint(off.scenario, settings: off.runSettings!)
                != SavedSimulationRun.fingerprint(snapshot.scenario, settings: snapshot.runSettings!))
        // Without glazing there is nothing to vent, and nothing is written.
        model.settings.ventsGlazing = true
        model.settings.scenario = Scenario(
            name: "Bare", domainSize: SIMD3(16, 20, 6), boxes: [],
            charge: Charge(mass: 5, position: SIMD3(7, 2, 1)))
        #expect(ProjectDocument(model: model).runSettings?.ventsGlazing == nil)
        // The standing says so.
        let inputs = snapshot.runSettings!.standingInputs(snapshot.scenario)
        #expect(inputs.options.contains(.ventedGlazing))
        #expect(!off.runSettings!.standingInputs(off.scenario).options.contains(.ventedGlazing))
    }

    @Test("New projects vent by default; projects glazed before keep their fill; gravity takes the fill")
    func defaults() throws {
        #expect(SimulationSettings().ventsGlazing)
        // A glazed project made now writes venting on.
        var made = ProjectDocument(scenario: try document(vented: false).scenario)
        #expect(made.runSettings?.ventsGlazing == true)
        // One saved before (no key) opens with the fill, as its runs had.
        made.runSettings?.ventsGlazing = nil
        let model = SimulationModel(document: made)
        #expect(!model.settings.ventsGlazing)
        // A project without glazing opens venting, for glazing added later.
        let bare = ProjectDocument(
            scenario: Scenario(
                name: "Bare", domainSize: SIMD3(16, 20, 6), boxes: [],
                charge: Charge(mass: 5, position: SIMD3(7, 2, 1))))
        #expect(bare.runSettings?.ventsGlazing == nil)
        #expect(SimulationModel(document: bare).settings.ventsGlazing)
        // With gravity the run takes the fill, and is saved as one.
        model.settings.ventsGlazing = true
        model.settings.gravity = true
        #expect(ProjectDocument(model: model).runSettings?.ventsGlazing == nil)
    }

    @Test("A headless run with venting breaks the pane in the air and reports the room's pressure")
    func headless() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "venting-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var judged: [Bool: EnvelopeBuildingDamage] = [:]
        for vented in [false, true] {
            let input = folder.appending(path: "glazed-\(vented).bombcad")
            let damage = folder.appending(path: "damage-\(vented).json")
            try document(vented: vented).makeArchive().fileWrapper().write(
                to: input, originalContentsURL: nil)
            let result = try await HeadlessRun.execute(
                HeadlessRun.Options.parse([input.path, "--envelope-damage", damage.path]))
            let building = try #require(
                JSONDecoder().decode([EnvelopeBuildingDamage].self, from: Data(contentsOf: damage)).first)
            judged[vented] = building
            #expect(result.streams.contains { $0.contains("(vented)") } == vented)
        }
        let fill = try #require(judged[false])
        let air = try #require(judged[true])
        #expect(fill.vented == nil && air.vented == true)
        // The pane breaks either way, near the same time; the inside is the air's room.
        #expect(fill.panesBroken == 1 && air.panesBroken == 1)
        let (one, other) = (try #require(fill.firstPaneBrokenAtS), try #require(air.firstPaneBrokenAtS))
        #expect(abs(one - other) < 2e-3, "one-way \(one) s, vented \(other) s")
        #expect(air.insidePeakPa > 100 && air.insideImpulsePaS > 0)
    }
}
