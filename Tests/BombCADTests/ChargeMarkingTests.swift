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
        let whole = network.posterior(marks: marks, reference: SIMD2(60, 60))
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
}
