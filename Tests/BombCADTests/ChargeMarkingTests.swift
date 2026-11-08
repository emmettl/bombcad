import BlastCore
import BlastRender
import Foundation
import Testing
import simd

@testable import BombCAD

/// Simulation ▸ Read the Charge from the Damage (emmettl/bombcad-work#116, stage 2): a click on a
/// building marks it while the panel is open, and the posterior's paint, outlines and words follow.
@MainActor
@Suite("Marking the damage to read the charge back", .serialized, .hangLimit)
struct ChargeMarkingTests {
    /// Six glazed blocks round a 50 kg charge in the middle of a 120 m square.
    static func document() throws -> (ProjectDocument, [UUID]) {
        var scene = Scenario(
            name: "Marking", domainSize: SIMD3(120, 120, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(60, 60, 0.5)))
        var ids: [UUID] = []
        for (n, corner) in [
            SIMD2<Float>(20, 20), SIMD2(70, 15), SIMD2(90, 60), SIMD2(15, 75), SIMD2(65, 85), SIMD2(35, 50),
        ].enumerated() {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(corner, 0), max: SIMD3(corner + 12, 9))]),
                name: "Block \(n + 1)")
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
            ids.append(id)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        return (document, ids)
    }

    @Test("A click marks the building under it, and the chance on the ground follows each mark")
    func marks() async throws {
        let (document, ids) = try Self.document()
        let model = SimulationModel(document: document)
        model.refinesCloseCalls = false
        let marking = model.chargeMarking
        func click(_ id: UUID) throws {
            let box = try #require(model.settings.scenario.object(id: id)?.bounds)
            let middle = (box.min + box.max) / 2
            model.camera = OrbitCamera(target: middle, distance: 60, azimuth: -2.6, elevation: 0.5)
            model.click(ndc: .zero, aspectRatio: 1)
        }
        // Closed, a click picks the building as before.
        try click(ids[0])
        #expect(model.selection == .building(ids[0]))
        #expect(marking.marking == nil)

        model.showsChargeMarking = true
        await marking.open(model)
        let network = try #require(marking.marking?.network)
        #expect(marking.marking?.reference == SIMD2(60, 60))
        try click(ids[1])
        #expect(marking.mark(of: ids[1])?.glass == .broken)
        let posterior = try #require(marking.posterior)
        #expect(abs(posterior.cellProbabilities.reduce(0, +) - 1) < 1e-9)
        #expect(!marking.words.isEmpty && marking.words.hasPrefix("Most likely"))
        // The paint: the grid with a bare ring, its likeliest cell at the top of the scale.
        let paint = try #require(marking.paint)
        let g = network.header.grid
        #expect(paint.patches.count == 1 && paint.patches[0].ground)
        #expect(paint.values.count == (g + 2) * (g + 2))
        #expect(paint.values.max() == 1)
        #expect(
            (0..<(g + 2)).allSatisfy { paint.values[$0] == 0 && paint.values[(g + 1) * (g + 2) + $0] == 0 })
        // The marked building outlined crimson over its roof, the regions in white.
        let kinds = stride(from: 0, to: marking.lines.count, by: 2).map { marking.lines[$0].w }
        #expect(kinds.filter { $0 == ChargeMarkingModel.LineKind.glassBroken }.count == 4)
        #expect(kinds.contains(ChargeMarkingModel.LineKind.half))
        #expect(kinds.contains(ChargeMarkingModel.LineKind.ninety))

        // Walls on another, whole glass on a third; the same brush again takes a mark away.
        marking.brush = .wallsHeavy
        try click(ids[2])
        marking.brush = .glassWhole
        try click(ids[3])
        #expect(marking.counts == .init(buildings: 3, glassBroken: 1, glassWhole: 1, heavy: 1))
        let three = try #require(marking.posterior)
        let marks = try #require(marking.marking?.orderedMarks)
        let whole = network.posterior(
            marks: marks, reference: SIMD2(60, 60), weighing: try #require(marking.marking?.weighing))
        #expect(
            zip(three.cellProbabilities, whole.cellProbabilities).map { abs($0 - $1) }.max() ?? 1 < 1e-4)
        try click(ids[3])
        #expect(marking.mark(of: ids[3]) == nil)
        #expect(marking.counts.buildings == 2)
        #expect(marking.weighSeconds > 0)

        // Searched about the likeliest place, then the charge moved there.
        await marking.centre(onCharge: false, model)
        #expect(!marking.aboutCharge)
        let likeliest = try #require(marking.posterior?.mostProbablePlace)
        marking.moveChargeThere(model)
        let charge = model.settings.chargePosition
        #expect(abs(Double(charge.x) - min(max(likeliest.x, 1), 119)) < 0.01)
        #expect(abs(Double(charge.y) - min(max(likeliest.y, 1), 119)) < 0.01)
        #expect(abs(charge.z - 0.5) < 1e-4)
        await marking.centre(onCharge: true, model)
        #expect(marking.aboutCharge)

        // From the quick estimate's damage: every building it judged.
        model.settings.chargePosition = SIMD3(60, 60, 0.5)
        model.settings.chargeMass = 50
        model.quickEstimate()
        while model.estimatingEnvelopeDamage || model.lookInFlight {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.envelopeDamage.isEmpty)
        await marking.markFromDamage(model)
        let seen = model.envelopeDamage.filter {
            let (glass, walls) = ChargeFromDamage.seen($0)
            return glass != nil || walls != nil
        }
        #expect(!seen.isEmpty)
        #expect(marking.counts.buildings == seen.count)

        marking.clearAll(model)
        #expect(marking.posterior == nil && marking.paint == nil && marking.words.isEmpty)
        #expect(marking.lines.isEmpty)
        // Closed again: clicks pick, and the view draws none of it.
        model.showsChargeMarking = false
        try click(ids[4])
        #expect(model.selection == .building(ids[4]))
    }

    @Test("The marks are kept with the project, and a survey is put on the scene's buildings")
    func keptAndSurveyed() async throws {
        let (document, ids) = try Self.document()
        // A project saved before stage 3 has none.
        #expect(try ProjectDocument(archive: document.makeArchive()).chargeMarks == nil)
        let model = SimulationModel(document: document)
        model.refinesCloseCalls = false
        let marking = model.chargeMarking
        model.showsChargeMarking = true
        await marking.open(model)
        #expect(marking.saved == nil)
        let buildings = ChargeFromDamage.buildings(scene: model.settings.scenario)
        marking.set(ChargeFromDamage.Mark(building: buildings[0], glass: .broken), for: ids[0], model)
        marking.set(ChargeFromDamage.Mark(building: buildings[2], walls: .damaged), for: ids[2], model)
        await marking.weigh(as: .independent, model)
        let saved = try #require(marking.saved)
        #expect(saved.marks.map(\.id) == [ids[0], ids[2]])
        #expect(saved.weighing == "independent")

        // Saved, read back and opened: the same marks on the same buildings, weighed as before.
        let archive = try ProjectDocument(model: model).makeArchive()
        #expect(archive.files["chargeMarks.json"] != nil)
        let reopened = try ProjectDocument(archive: archive)
        #expect(reopened.chargeMarks == saved)
        let again = SimulationModel(document: reopened)
        again.refinesCloseCalls = false
        #expect(again.chargeMarking.saved == saved)
        again.showsChargeMarking = true
        await again.chargeMarking.open(again)
        #expect(again.chargeMarking.mark(of: ids[0])?.glass == .broken)
        #expect(again.chargeMarking.mark(of: ids[2])?.walls == .damaged)
        #expect(again.chargeMarking.weighing == .independent)
        let before = try #require(marking.posterior)
        let after = try #require(again.chargeMarking.posterior)
        #expect(zip(before.cellProbabilities, after.cellProbabilities).map { abs($0 - $1) }.max() ?? 1 < 1e-6)

        // A marks CSV about the scene's charge: two buildings found, one place with none near.
        let csv = FileManager.default.temporaryDirectory.appending(path: "survey-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csv) }
        // Block 2's middle is (76, 21) and block 5's (71, 91); the charge is at (60, 60).
        try """
        building,east,north,height,footprint,built,walls,glass,seen
        -1,16,-39,9,144,0.1,concrete,broken,-
        -1,11,31,9,144,0.1,masonry,-,heavy
        -1,-55,55,9,144,0.1,concrete,whole,-
        """.write(to: csv, atomically: true, encoding: .utf8)
        await again.chargeMarking.loadSurvey(csv, again)
        #expect(again.chargeMarking.error == nil)
        #expect(again.chargeMarking.mark(of: ids[1])?.glass == .broken)
        #expect(again.chargeMarking.mark(of: ids[4])?.walls == .heavy)
        #expect(again.chargeMarking.mark(of: ids[4])?.building.walls == .masonry)
        #expect(again.chargeMarking.mark(of: ids[0]) == nil)
        #expect(again.chargeMarking.counts.buildings == 2)
        #expect(again.chargeMarking.surveyReport.contains("2 of 3 entries matched, on 2 buildings"))
        #expect(again.chargeMarking.surveyReport.contains("1 unmatched"))
        // The stone kept as masonry when saved.
        #expect(again.chargeMarking.saved?.marks.first { $0.id == ids[4] }?.wallsAs == .masonry)
        // A GEER file needs the corner.
        let geer = FileManager.default.temporaryDirectory.appending(path: "geer-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: geer) }
        try "lat,lon,class\n33.9,35.5,2\n".write(to: geer, atomically: true, encoding: .utf8)
        await again.chargeMarking.loadSurvey(geer, again)
        #expect(again.chargeMarking.error?.contains("corner") == true)
        #expect(again.chargeMarking.counts.buildings == 2)
        // A scene that knows its place on the map needs no corner typed, and keeps it when saved.
        let corner = SIMD2(35.5, 33.9)
        again.sceneLocation = SceneLocation(corner: corner)
        let block = try #require(again.settings.scenario.envelopeObjects.first { $0.id == ids[0] })
        let middle = try #require(block.envelope?.blocks.first).middleForTest
        let east = ElevationGrid.metresPerDegree * cos(corner.y * .pi / 180)
        let there = corner + SIMD2(Double(middle.x) / east, Double(middle.y) / ElevationGrid.metresPerDegree)
        try "lat,lon,class\n\(there.y),\(there.x),2\n".write(to: geer, atomically: true, encoding: .utf8)
        await again.chargeMarking.loadSurvey(geer, again)
        #expect(again.chargeMarking.error == nil)
        #expect(again.chargeMarking.mark(of: ids[0])?.glass == .broken)
        #expect(ProjectDocument(model: again).location == again.sceneLocation)
    }
}

extension Box {
    fileprivate var middleForTest: SIMD2<Float> { SIMD2((min.x + max.x) / 2, (min.y + max.y) / 2) }
}
