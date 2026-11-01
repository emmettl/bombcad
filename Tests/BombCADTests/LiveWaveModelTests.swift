import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// The live blast wave in the app's model (docs/live-wave.md): shown, it is worked out for the
/// charge where it is, follows it as it moves, plays and scrubs, and is let go when hidden.
@MainActor
@Suite("The live blast wave in the model", .serialized, .hangLimit)
struct LiveWaveModelTests {
    func waitForWave(_ model: SimulationModel, charge: SIMD3<Float>? = nil) async throws {
        while model.liveWave == nil || model.liveWaveInFlight
            || (charge != nil && model.liveWaveShownFor?.charge != charge)
        {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Shown, it is worked out, follows the charge, plays, scrubs and is let go")
    func showFollowPlayHide() async throws {
        var document = ProjectDocument(scenario: ScenarioPreset.streetCanyon.scenario)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.liveWaveSummary == nil)
        model.liveWaveShown = true
        try await waitForWave(model)
        let first = try #require(model.liveWave)
        #expect(model.drawsLiveWave)
        #expect(first.lastArrival > 0)
        // First shown at its end: every peak and shadow.
        #expect(abs(model.liveWaveTime - Double(first.lastArrival)) < 1e-9)
        #expect(model.liveWaveStatus.contains("Not a run"))
        #expect(model.viewportSummary.contains("blast wave estimate"))

        // The charge moved: worked out again for the new place.
        var moved = model.settings.chargePosition
        moved.x += 4
        model.settings.chargePosition = moved
        try await waitForWave(model, charge: moved)
        #expect(model.liveWave?.arrival != first.arrival)

        // Scrubbed to the start, then played: the time runs on, and stops at the end.
        model.scrubLiveWave(to: 0)
        #expect(model.liveWaveTime == 0)
        model.setLiveWaveSpeed(.realTime)
        model.playLiveWave()
        #expect(model.liveWavePlaying)
        while model.liveWavePlaying {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(model.liveWaveTime - model.liveWaveEnd) < 1e-9)
        #expect(model.liveWaveSummary?.contains("of the plan reached") == true)

        model.liveWaveShown = false
        #expect(model.liveWave == nil && !model.liveWavePlaying && model.liveWaveStatus.isEmpty)
        #expect(!model.drawsLiveWave)
    }

    @Test("A large plan is worked out on coarser cells while the charge is dragged")
    func coarseWhileDragging() {
        var scene = ScenarioPreset.streetCanyon.scenario
        #expect(SimulationModel.liveWaveCell(for: scene, dragging: true) == 4)
        // Beirut's 5 km: 1.56 million 4 m cells, 0.39 million 8 m ones while dragging.
        scene.domainSize = SIMD3(5000, 5000, 160)
        #expect(SimulationModel.liveWaveCell(for: scene, dragging: false) == 4)
        #expect(SimulationModel.liveWaveCell(for: scene, dragging: true) == 8)
    }
}
