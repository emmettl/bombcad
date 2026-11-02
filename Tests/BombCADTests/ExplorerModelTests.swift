import BlastCore
import BlastRender
import Foundation
import Testing
import simd

@testable import BombCAD

/// The explorer in the app (emmettl/bombcad-work#114; docs/explorer.md): the square opened, the wave
/// worked out with its captions, the layers coloured, and the comparisons against a pinned picture.
@MainActor
@Suite("The explorer", .serialized, .hangLimit)
struct ExplorerModelTests {
    /// Waits for the estimate, the wave and the fire to settle.
    func settle(_ model: SimulationModel) async throws {
        while model.estimatingEnvelopeDamage || model.isLoadingInputs || model.liveWaveInFlight
            || model.envelopeEstimateIsPreview || model.fireTask != nil
        {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Opens the square, plays the wave with captions, colours each layer and compares")
    func square() async throws {
        let model = SimulationModel(document: ProjectDocument.newProject())
        try await settle(model)
        let explorer = ExplorerModel(model: model)
        explorer.reduceMotion = true
        await explorer.open(.square)
        try await settle(model)
        #expect(explorer.problem == nil)
        #expect(explorer.scene == .square)
        #expect(model.settings.scenario.envelopeObjects.count == 398)
        #expect(model.settings.chargeMass == 500)
        #expect(!model.refinesCloseCalls && model.isPlacingCharge)
        #expect(explorer.place?.name == "In the middle of the square")
        // The estimate in, and the wave with its four captions; Reduce Motion shows it whole.
        #expect(!model.envelopeGlassChances.isEmpty)
        #expect(explorer.captions.count == 4)
        explorer.replay()
        #expect(model.liveWaveTime == model.liveWaveEnd)
        #expect(explorer.caption?.contains("crossed the whole scene") == true)
        #expect(explorer.viewSummary.hasPrefix("A square; 500 kg of TNT in the middle of the square"))

        // No solver here: the air's starting ball is not drawn, and the charge's marker is large enough to see.
        #expect(!model.renderSettings.showWave && model.renderSettings.chargeMarkerRadius > 1)
        #expect(model.renderSettings.chargeMarkerOutlined)
        // The layers: the wave on plain buildings, the glass by the explorer's own score, the wave
        // then not drawn over it.
        #expect(!model.showsEnvelopeDamage && model.explorerColouring == nil && !model.explorerHidesLiveWave)
        // On the wave layer no preview while dragging; the explorer's warm scale; a coarser wave to drag.
        #expect(!model.previewsWhileDragging && model.explorerWarmRamp)
        #expect(model.liveWaveDragCoarsening == ExplorerModel.dragCoarsening && !model.liveWaveDragRefines)
        explorer.layer = .glass
        #expect(model.showsEnvelopeDamage && model.explorerColouring == .glass && model.explorerHidesLiveWave)
        #expect(model.previewsWhileDragging)
        #expect(explorer.finding?.hasPrefix("Windows break") == true)
        explorer.layer = .walls
        #expect(model.envelopeColouring == .wallsModerate && model.explorerColouring == nil)
        explorer.layer = .fire
        #expect(model.envelopeColouring == .fire && model.fireSettings.nearChargeM == 40)
        try await settle(model)
        #expect(model.fireLayer != nil)

        // Glass with film against the picture pinned: less glass thrown into the rooms; the people
        // estimate, counting panes broken, cannot see it.
        explorer.run(.glassWithFilm)
        #expect(explorer.pinned != nil && explorer.layer == .glass && explorer.showsChange)
        #expect(model.quickEstimateWhatIf.glass == ExplorerModel.film)
        try await settle(model)
        guard case .change(_, .thrown)? = model.explorerColouring else {
            Issue.record("not coloured by the change")
            return
        }
        let filmed = try #require(explorer.comparison)
        #expect(filmed.contains("less broken glass flies into the rooms at"), "\(filmed)")
        #expect(filmed.contains(ExplorerWords.filmAndPeople), "\(filmed)")

        // Twice the charge, from the picture put back.
        explorer.putBack()
        try await settle(model)
        #expect(model.quickEstimateWhatIf.isEmpty)
        explorer.run(.twiceTheCharge)
        try await settle(model)
        #expect(model.settings.chargeMass == 1_000)
        let twice = try #require(explorer.comparison)
        #expect(twice.contains("cube root"), "\(twice)")
        // The faint ring at the pinned picture's reach, round the pinned charge.
        let reach = try #require(explorer.pinnedReach)
        #expect(!model.explorerLines.isEmpty && model.explorerLines.count % 2 == 0)
        let first = model.explorerLines[0]
        let pinnedCharge = try #require(explorer.pinned?.charge)
        #expect(
            abs(simd_length(SIMD2(first.x - pinnedCharge.x, first.y - pinnedCharge.y)) - Float(reach)) < 0.5)

        // Behind the terrace: the charge at the named place.
        explorer.run(.behindABuilding)
        try await settle(model)
        #expect(model.settings.chargeMass == 500)
        #expect(explorer.place?.name == "In the street behind the brick terrace")
        #expect(explorer.comparison?.contains("Against the pinned picture") == true)
        explorer.unpin()
        #expect(explorer.pinned == nil && model.peopleBaseline == nil)
        explorer.close()
        #expect(explorer.scene == nil && !model.liveWaveShown)
        #expect(!model.explorerWarmRamp && model.previewsWhileDragging && model.liveWaveDragCoarsening == 2)
    }

    @Test("Opens the street at its named places; Beirut asks to be downloaded first")
    func streetAndBeirut() async throws {
        let model = SimulationModel(document: ProjectDocument.newProject())
        try await settle(model)
        let explorer = ExplorerModel(model: model)
        explorer.reduceMotion = true
        // Beirut's file not here: one prompt, nothing opened.
        setenv("BOMBCAD_EXPLORER_BEIRUT", "/nonexistent/explorer-beirut.json", 1)
        defer { unsetenv("BOMBCAD_EXPLORER_BEIRUT") }
        await explorer.open(.beirut)
        #expect(explorer.offersBeirutDownload && explorer.scene == nil)
        #expect(explorer.beirutOffer.hasPrefix(ExplorerScene.Beirut.Release.offer))
        #expect(explorer.beirutDownloadTitle.hasPrefix("Download "))
        explorer.offersBeirutDownload = false

        await explorer.open(.street)
        try await settle(model)
        #expect(explorer.scene == .street && explorer.problem == nil)
        #expect(model.settings.scenario.envelopeObjects.count == ExplorerScene.street.buildings().count)
        #expect(explorer.place?.name == "In the middle of the high street")
        explorer.put(at: try #require(ExplorerScene.street.place("Outside the bank")))
        try await settle(model)
        #expect(explorer.place?.name == "Outside the bank")
        #expect(!model.envelopeGlassChances.isEmpty)
        explorer.close()
    }

    @Test("The speed plays a wave in about five seconds")
    func speed() {
        #expect(ExplorerModel.speed(for: 0.8) == .quarter)
        #expect(ExplorerModel.speed(for: 12) == .realTime)
        #expect(ExplorerModel.speed(for: 0.06) == .fiftieth)
    }
}
