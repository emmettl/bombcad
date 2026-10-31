import BlastCore
import BlastRender
import Foundation
import Testing
import simd

@testable import BombCAD

/// Fire after the blast in the app (emmettl/bombcad-work#38, stage 3): the quick estimate's glass
/// carries a fire from the seeds picked, drawn away from the main thread, a preview while a control
/// moves and the full ensemble after, cancelled by a newer request; the view coloured by the hour.
@MainActor
@Suite("Fire after the blast", .serialized)
struct FireAfterBlastTests {
    /// Six glazed buildings 6 m apart in two rows round a 50 kg charge.
    static func street() throws -> (ProjectDocument, [UUID]) {
        var scene = Scenario(
            name: "Fire street", domainSize: SIMD3(160, 60, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 30, 0.5)))
        var ids: [UUID] = []
        for (x, y) in [(Float(40), Float(18)), (56, 18), (72, 18), (40, 36), (56, 36), (72, 36)] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, y, 0), max: SIMD3(x + 10, y + 6, 9))]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
            ids.append(id)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        return (document, ids)
    }

    func settle(_ model: SimulationModel) async throws {
        while model.estimatingEnvelopeDamage || model.isLoadingInputs || model.fireTask != nil
            || model.fireProgress != nil
        {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test(
        "Seeds picked set the fire going on the quick estimate's glass; the hour recolours; previews follow a slider"
    )
    func layer() async throws {
        let (document, ids) = try Self.street()
        let model = SimulationModel(document: document)
        model.refinesCloseCalls = false
        try await settle(model)
        #expect(model.fireSource == nil)
        model.quickEstimate()
        try await settle(model)
        #expect(model.fireSource != nil)
        // No seeds: nothing drawn, and the user asked where fires start.
        #expect(model.fireLayer == nil)
        #expect(model.fireStatus.hasPrefix("Choose where fires start"))

        // A building picked: the full ensemble, the seed certain from the blast.
        model.toggleFireSeed(ids[0])
        #expect(model.firePicked(ids[0]))
        #expect(model.fireProgress?.of == SimulationModel.fireDraws.full)
        try await settle(model)
        let full = try #require(model.fireLayer)
        #expect(!full.preview && full.members == SimulationModel.fireDraws.full)
        #expect(full.ids == ids && full.fixedSeeds == 1)
        #expect(full.chance(0, at: 0) == 1)
        #expect(model.fireStatus.contains("200 draws over 12 h"))

        // Coloured by the fire: every building, the seed outlined.
        model.showsEnvelopeDamage = true
        model.envelopeColouring = .fire
        #expect(model.previewParts == .glass)
        #expect(model.fireMapChance == .neighbour)
        let codes = model.fireCodes()
        #expect(codes.count == ids.count)
        // By the chance of catching from a neighbour: on the ramp where some draw it was not a seed in
        // has it caught, grey where none does; the seed, a seed in every draw, grey under its outline.
        let t = model.fireHour * 3600
        #expect(
            ids.indices.allSatisfy { n in
                full.neighbourChance(n, at: t) > 0
                    ? codes[ids[n]]! >= EnvelopeChanceColour.first
                    : codes[ids[n]] == EnvelopeChanceColour.neutral
            })
        #expect(codes[ids[0]] == EnvelopeChanceColour.neutral)
        #expect(model.fireSeedOutlines().count == 8)
        // With a seed picked by hand, the others are coloured as the earlier map colours them.
        model.fireMapChance = .caught
        let caught = model.fireCodes()
        #expect(
            ids.indices.allSatisfy { n in
                full.chance(n, at: t) > 0
                    ? caught[ids[n]]! >= EnvelopeChanceColour.first
                    : caught[ids[n]] == EnvelopeChanceColour.neutral
            })
        #expect(caught[ids[0]]! >= EnvelopeChanceColour.first)
        #expect(ids.dropFirst().allSatisfy { caught[$0] == codes[$0] })
        // Alight then, past the seed's own fire: it is out.
        model.fireShowsAlight = true
        model.fireHour = (full.ensemble.buildings[0].burnS + 900) / 3600
        #expect(model.fireCodes()[ids[0]] == EnvelopeChanceColour.neutral)
        model.fireShowsAlight = false
        model.fireMapChance = .neighbour

        // A slider held: a preview's few draws; let go, the full ensemble again.
        model.fireAdjusting = true
        model.fireSettings.wind = .init(speedMS: 8, fromDegrees: 270)
        try await settle(model)
        #expect(model.fireLayer?.preview == true)
        #expect(model.fireLayer?.members == SimulationModel.fireDraws.preview)
        model.fireAdjusting = false
        try await settle(model)
        #expect(model.fireLayer?.preview == false)
        #expect(model.fireLayer?.ensemble.wind.speedMS == 8)

        // A newer request cancels the one under way: only the last is shown.
        model.fireSettings.hours = 6
        model.fireSettings.hours = 3
        try await settle(model)
        #expect(model.fireLayer?.horizonS == 10_800.0)
        #expect(model.fireHour <= 3)

        // Every building timber-clad: the fire catches at least as often everywhere.
        let asBuilt = try #require(model.fireLayer)
        model.fireSettings.cladding = .combustible
        try await settle(model)
        let timber = try #require(model.fireLayer)
        #expect(timber.combustible == ids.count)
        #expect(timber.ensemble.caught.y >= asBuilt.ensemble.caught.y)

        // Near the charge, and at random: seeds without picking.
        model.fireSettings = FireSpread.LayerSettings()
        #expect(model.fireLayer == nil)
        model.fireSettings.nearChargeM = 25
        try await settle(model)
        #expect(model.fireLayer?.fixedSeeds == 2)
        model.fireSettings.nearChargeM = nil
        model.fireSettings.randomCount = 2
        model.fireSettings.randomFromM = 0
        model.fireSettings.randomToM = 1000
        try await settle(model)
        #expect(model.fireLayer?.randomCandidates == ids.count)
        #expect(model.fireStatus.contains("2 at random a draw"))
        // At random: each building's chance from a neighbour leaves out the draws it was a seed in,
        // so it is never more than its chance of catching at all.
        let random = try #require(model.fireLayer)
        let end = random.horizonS
        #expect(random.ids.indices.contains { random.ensemble.buildings[$0].seedDraws > 0 })
        #expect(
            random.ids.indices.allSatisfy {
                random.neighbourChance($0, at: end) <= random.chance($0, at: end) + 1e-12
            })
        // No run, so no surface heating to seed from.
        #expect(model.fireThermal == nil)

        // A click on a building while picking: alight; again: not.
        model.fireSettings = FireSpread.LayerSettings()
        model.firePicksSeeds = true
        model.camera = OrbitCamera(target: SIMD3(61, 39, 0), distance: 60, azimuth: -1.57, elevation: 1.5)
        model.click(ndc: .zero, aspectRatio: 1)
        #expect(model.fireSettings.picked == [ids[4]])
        model.click(ndc: .zero, aspectRatio: 1)
        #expect(model.fireSettings.picked.isEmpty)
        model.firePicksSeeds = false
        model.click(ndc: .zero, aspectRatio: 1)
        #expect(model.fireSettings.picked.isEmpty)

        // The scene loaded again lets the fire go with the estimate.
        model.fireSettings.picked = [ids[1]]
        try await settle(model)
        #expect(model.fireLayer != nil)
        model.requestRebuild()
        #expect(model.fireLayer == nil && model.fireTask == nil)
        try await settle(model)
        #expect(model.fireSource == nil && model.fireLayer == nil)
    }
}
